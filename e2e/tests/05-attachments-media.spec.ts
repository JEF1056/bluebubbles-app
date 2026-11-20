import {
  test,
  expect,
  bootAuthenticated,
  openChat,
} from '../fixtures/test';
import { SAMPLE_PNG_BYTES, DEFAULT_PASSWORD, makeAttachment } from '../server/fixtures-data';

const DM_CHAT_GUID = 'iMessage;-;+15550100001';

test.describe('Attachments & Media', () => {
  test('seeded image attachment fetches with CORP header, renders, and opens/dismisses fullscreen viewer', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const downloadResponsePromise = page.waitForResponse(
      (res) =>
        res.url().includes('/api/v1/attachment/att-seed-img-1/download') &&
        res.request().method() === 'GET',
    );

    await openChat(page, 'Alex Mercer');

    const downloadResp = await downloadResponsePromise;
    expect(downloadResp.status()).toBe(200);
    expect(downloadResp.headers()['cross-origin-resource-policy']).toBe('cross-origin');
    expect(downloadResp.headers()['access-control-allow-origin']).toBeTruthy();

    const screenshotCaption = page.getByText('Check out this screenshot!');
    await expect(screenshotCaption).toBeVisible();

    // Open fullscreen viewer by clicking the rendered image attachment bubble (locale-independent).
    const imageBubble = page
      .getByRole('group')
      .filter({ hasText: 'Check out this screenshot!' })
      .last()
      .getByRole('button')
      .filter({ hasNotText: 'Check out this screenshot!' })
      .first();
    const viewerControl = page
      .getByRole('button', { name: /Save|Details|Zoom in \(\+\)|Done/i })
      .or(page.getByText('Done', { exact: true }))
      .first();
    await expect(imageBubble).toBeVisible();
    // Retry click in case the tap lands right after HTTP 200 before Flutter finishes decoding the image.
    await expect(async () => {
      await imageBubble.click({ force: true });
      await expect(viewerControl).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });
    await page.keyboard.press('Escape');
    await expect(viewerControl).not.toBeVisible({ timeout: 10_000 });
    await expect(screenshotCaption).toBeVisible({ timeout: 10_000 });

    errors.assertNoFatalErrors();
  });

  test('Range media request returns 206 Partial Content with CORS and CORP headers', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const targetUrl = `${bbServer.url}/api/v1/attachment/att-seed-img-1/download?guid=${encodeURIComponent(DEFAULT_PASSWORD)}`;
    const rangeRespPromise = page.waitForResponse(
      (res) =>
        res.url().includes('/api/v1/attachment/att-seed-img-1/download') &&
        res.request().method() === 'GET' &&
        res.status() === 206,
    );
    const result = await page.evaluate(async (url) => {
      const headRes = await fetch(url, { method: 'HEAD' });
      const rangeRes = await fetch(url, {
        headers: { Range: 'bytes=0-15' },
      });
      const buf = await rangeRes.arrayBuffer();
      return {
        headStatus: headRes.status,
        headAcceptRanges: headRes.headers.get('accept-ranges'),
        headContentLength: headRes.headers.get('content-length'),
        rangeStatus: rangeRes.status,
        contentRange: rangeRes.headers.get('content-range'),
        acceptRanges: rangeRes.headers.get('accept-ranges'),
        byteLength: buf.byteLength,
      };
    }, targetUrl);

    const rangeResp = await rangeRespPromise;
    expect(rangeResp.headers()['cross-origin-resource-policy']).toBe('cross-origin');
    expect(rangeResp.headers()['access-control-allow-origin']).toBeTruthy();

    expect(result.headStatus).toBe(200);
    expect(result.headAcceptRanges).toBe('bytes');
    expect(Number(result.headContentLength)).toBe(SAMPLE_PNG_BYTES.length);

    expect(result.rangeStatus).toBe(206);
    expect(result.contentRange).toBe(`bytes 0-15/${SAMPLE_PNG_BYTES.length}`);
    expect(result.acceptRanges).toBe('bytes');
    expect(result.byteLength).toBe(16);

    errors.assertNoFatalErrors();
  });

  test('uploads and sends file attachment via multipart POST and renders incoming socket attachment', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    const composer = page.getByRole('textbox').last();
    await expect(composer).toBeVisible();

    const addAttachmentBtn = page.getByRole('button', { name: 'Add attachment' });
    await expect(addAttachmentBtn).toBeVisible();
    await addAttachmentBtn.click({ force: true });

    const uploadTile = page.getByText(/Files|Upload file/).first();
    await expect(uploadTile).toBeVisible();

    const [fileChooser] = await Promise.all([
      page.waitForEvent('filechooser'),
      uploadTile.click(),
    ]);
    await fileChooser.setFiles({
      name: 'upload-test.png',
      mimeType: 'image/png',
      buffer: SAMPLE_PNG_BYTES,
    });

    const uploadReqPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/message/attachment',
    );
    await composer.click({ force: true });
    await page.keyboard.press('Enter');

    const uploadReq = await uploadReqPromise;
    expect(uploadReq.headers['content-type']).toContain('multipart/form-data');
    const uploadedFiles = Object.values(uploadReq.files ?? {});
    expect(uploadedFiles.some((f) => f.filename === 'upload-test.png' && f.data.length === SAMPLE_PNG_BYTES.length)).toBe(true);

    // Emit an incoming message with a new image attachment over socket.io.
    const liveDownloadPromise = page.waitForResponse(
      (res) =>
        res.url().includes('/api/v1/attachment/att-live-img-1/download') &&
        res.request().method() === 'GET',
    );

    bbServer.emitNewMessage(DM_CHAT_GUID, {
      guid: 'msg-live-att-1',
      text: 'Live attachment arrived',
      isFromMe: false,
      attachments: [
        makeAttachment({
          guid: 'att-live-img-1',
          mimeType: 'image/png',
          transferName: 'live.png',
          totalBytes: SAMPLE_PNG_BYTES.length,
          bytes: SAMPLE_PNG_BYTES,
        }),
      ],
    });

    await expect(page.getByText('Live attachment arrived')).toBeVisible();
    const liveResp = await liveDownloadPromise;
    expect(liveResp.status()).toBe(200);

    errors.assertNoFatalErrors();
  });
});
