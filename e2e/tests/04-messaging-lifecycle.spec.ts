import { test, expect, bootAuthenticated, openChat, sendMessage } from '../fixtures/test';
import type { Page } from '@playwright/test';

const DM_GUID = 'iMessage;-;+15550100001';
const GROUP_GUID = 'iMessage;+;chat1000000000000001';
const SEEDED_DM_TEXT = 'Hey! Ready for the BlueBubbles E2E test?';

function msgLocator(page: Page, text: string) {
  return page.getByLabel(text, { exact: false }).or(page.getByText(text, { exact: false })).first();
}

async function sendTextReliably(page: Page, text: string) {
  const composer = page
    .getByRole('textbox', { name: /Text message|iMessage|New Message|Text Message/i })
    .last();
  await composer.waitFor({ state: 'visible', timeout: 15_000 });
  await expect(async () => {
    await composer.focus();
    const mod = process.platform === 'darwin' ? 'Meta' : 'Control';
    await page.keyboard.press(`${mod}+a`);
    await page.keyboard.press('Backspace');
    await composer.pressSequentially(text);
    await expect(composer).toHaveValue(text, { timeout: 1_500 });
  }).toPass({ timeout: 10_000 });
  await expect(async () => {
    await composer.focus();
    await page.keyboard.press('Enter');
    await expect(composer).toHaveValue('', { timeout: 1_500 });
  }).toPass({ timeout: 10_000 });
}

async function openMessagePopup(
  page: Page,
  messageText: string,
  align: 'left' | 'right' = 'left',
) {
  const target = page
    .getByText(messageText, { exact: false })
    .or(page.getByLabel(messageText, { exact: false }))
    .first();
  await target.waitFor({ state: 'visible', timeout: 15_000 });

  const popupReady = page
    .getByRole('button', { name: '❤️' })
    .or(page.getByRole('button', { name: 'Reply' }))
    .or(page.getByRole('button', { name: /More actions|More/i }))
    .first();

  await expect(async () => {
    if (await popupReady.isVisible().catch(() => false)) return;
    let prev: { x: number; y: number; width: number; height: number } | null = null;
    await expect(async () => {
      const b = await target.boundingBox();
      expect(b).not.toBeNull();
      if (prev && Math.abs(b!.y - prev.y) < 1 && Math.abs(b!.height - prev.height) < 1) {
        return;
      }
      prev = b;
      throw new Error('Message still animating');
    }).toPass({ timeout: 3_000 });
    const box = prev as { x: number; y: number; width: number; height: number } | null;
    if (box) {
      // Message row semantics span the full pane width; click inside the aligned bubble,
      // otherwise right-clicking empty row space triggers SelectionArea's Copy/Select All menu.
      const x =
        box.width > 450
          ? align === 'left'
            ? box.x + Math.min(130, box.width * 0.2)
            : box.x + box.width - Math.min(80, box.width * 0.1)
          : align === 'left'
            ? box.x + Math.min(100, box.width * 0.25)
            : box.x + box.width - Math.min(80, box.width * 0.2);
      await page.mouse.click(x, box.y + box.height / 2, { button: 'right' });
    } else {
      await target.click({ button: 'right', force: true });
    }
    await expect(popupReady).toBeVisible({ timeout: 3_000 });
  }).toPass({ timeout: 15_000 });
}

async function clickPopupAction(page: Page, actionName: string) {
  const direct = page
    .getByRole('button', { name: actionName })
    .or(page.getByRole('menuitem', { name: actionName }))
    .or(page.getByText(actionName, { exact: true }))
    .first();
  if (await direct.isVisible().catch(() => false)) {
    await direct.click({ force: true });
    return;
  }

  // Material docked toolbar moves items beyond slot 4 into "More actions" ("More")
  const moreBtn = page
    .getByRole('button', { name: /More actions|More/i })
    .or(page.getByText('More', { exact: true }))
    .first();
  await moreBtn.waitFor({ state: 'visible', timeout: 10_000 });
  await moreBtn.click({ force: true });

  const menuItem = page
    .getByRole('menuitem', { name: actionName })
    .or(page.getByText(actionName, { exact: true }))
    .first();
  await menuItem.waitFor({ state: 'visible', timeout: 10_000 });
  await menuItem.click({ force: true });
}

async function switchToChat(page: Page, chatTitle: string) {
  const chatTile = page
    .getByRole('button', { name: new RegExp(chatTitle) })
    .or(page.getByText(chatTitle, { exact: false }))
    .first();
  if (!(await chatTile.isVisible().catch(() => false))) {
    const namedBack = page.getByRole('button', { name: 'Back' }).first();
    if (await namedBack.isVisible().catch(() => false)) {
      await namedBack.click({ force: true });
    } else {
      const unnamedBack = page.locator('flt-semantics[role="button"]:not([aria-label])').first();
      if (await unnamedBack.isVisible().catch(() => false)) {
        await unnamedBack.click({ force: true });
      }
    }
  }
  await openChat(page, chatTitle);
}

test.describe('Messaging Lifecycle', () => {
  test('sends text message with valid payload and updates receipt from Delivered to Read via socket', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    const text = `Lifecycle hello ${Date.now()}`;
    const postPromise = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendMessage(page, text);

    const req = await postPromise;
    expect(req.body?.chatGuid).toBe(DM_GUID);
    expect(req.body?.message).toBe(text);
    expect(typeof req.body?.tempGuid).toBe('string');
    expect(String(req.body?.tempGuid).length).toBeGreaterThan(0);

    await expect(msgLocator(page, text)).toBeVisible({ timeout: 15_000 });

    const sentMsg = (bbServer.seed.messagesByChat[DM_GUID] ?? []).find((m) => m.text === text);
    expect(sentMsg).toBeDefined();

    bbServer.emitUpdatedMessage(DM_GUID, {
      guid: sentMsg!.guid,
      dateDelivered: Date.now(),
      dateRead: Date.now(),
    });

    await expect(
      page.getByLabel(/\bRead\b/).or(page.getByText(/\bRead\b/)).first(),
    ).toBeVisible({ timeout: 15_000 });
    errors.assertNoFatalErrors();
  });

  test('receives live incoming 1:1 and group messages via Socket.IO', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    const dmIncoming = `Incoming 1:1 ${Date.now()}`;
    bbServer.emitNewMessage(DM_GUID, {
      text: dmIncoming,
      isFromMe: false,
    });
    await expect(msgLocator(page, dmIncoming)).toBeVisible({ timeout: 15_000 });

    await switchToChat(page, 'Weekend Crew');

    const groupIncoming = `Incoming group ${Date.now()}`;
    const samHandle = bbServer.seed.handles[2];
    bbServer.emitNewMessage(GROUP_GUID, {
      text: groupIncoming,
      isFromMe: false,
      handle: samHandle,
      handleId: samHandle.originalROWID,
    });
    await expect(msgLocator(page, groupIncoming)).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });

  test('shows and hides typing indicator via typing-indicator socket event', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    // Wait for the header avatar ("A") to mount before sampling baseline count
    await page.getByRole('banner').getByRole('button', { name: 'A', exact: true }).waitFor({
      state: 'visible',
      timeout: 10_000,
    });
    const avatarLocator = page.getByRole('button', { name: 'A', exact: true });
    const baselineCount = await avatarLocator.count();

    bbServer.emitTyping(DM_GUID, true);
    await expect(async () => {
      expect(await avatarLocator.count()).toBeGreaterThan(baselineCount);
    }).toPass({ timeout: 10_000 });

    bbServer.emitTyping(DM_GUID, false);
    await expect(async () => {
      expect(await avatarLocator.count()).toBe(baselineCount);
    }).toPass({ timeout: 10_000 });

    errors.assertNoFatalErrors();
  });

  test('sends tapback reaction via POST /api/v1/message/react and renders incoming tapback', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    await openMessagePopup(page, SEEDED_DM_TEXT, 'left');

    const reactPromise = bbServer.waitForRequest('POST', '/api/v1/message/react', 15_000);
    const heartBtn = page
      .getByRole('button', { name: '❤️' })
      .or(page.getByLabel('❤️'))
      .or(page.getByText('❤️', { exact: true }))
      .first();
    await heartBtn.waitFor({ state: 'visible', timeout: 10_000 });
    await heartBtn.click({ force: true });

    const reactReq = await reactPromise;
    expect(reactReq.body?.chatGuid).toBe(DM_GUID);
    expect(reactReq.body?.selectedMessageGuid).toBe('msg-dm-1');
    expect(reactReq.body?.reaction).toBe('love');

    // Incoming tapback from Jordan on msg-dm-2 via Socket.IO; sample baseline first so desktop's left-pane tile cannot pass vacuously
    const jordanTapback = page.getByLabel('Jordan Lee').or(page.getByText('Jordan Lee'));
    const baselineJordanCount = await jordanTapback.count();

    const jordanHandle = bbServer.seed.handles[1];
    bbServer.emitNewMessage(DM_GUID, {
      text: '',
      isFromMe: false,
      handle: jordanHandle,
      handleId: jordanHandle.originalROWID,
      associatedMessageGuid: 'p:0/msg-dm-2',
      associatedMessagePart: 0,
      associatedMessageType: 'like',
    });

    await expect(msgLocator(page, 'Check out this screenshot!')).toBeVisible({ timeout: 10_000 });
    await expect(async () => {
      expect(await jordanTapback.count()).toBeGreaterThan(baselineJordanCount);
    }).toPass({ timeout: 10_000 });
    errors.assertNoFatalErrors();
  });

  test('sends a threaded reply with selectedMessageGuid', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    await openMessagePopup(page, SEEDED_DM_TEXT, 'left');
    await clickPopupAction(page, 'Reply');

    // ReplyHolder previews the quoted message above the composer
    const quoteOccurrences = page
      .getByLabel(SEEDED_DM_TEXT, { exact: false })
      .or(page.getByText(SEEDED_DM_TEXT, { exact: false }));
    await expect(async () => {
      expect(await quoteOccurrences.count()).toBeGreaterThanOrEqual(2);
    }).toPass({ timeout: 10_000 });

    const replyText = `ThreadReply-${Date.now()}`;
    const postPromise = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendTextReliably(page, replyText);

    const req = await postPromise;
    expect(req.body?.chatGuid).toBe(DM_GUID);
    expect(req.body?.message).toBe(replyText);
    expect(req.body?.selectedMessageGuid).toBe('msg-dm-1');

    await expect(msgLocator(page, replyText)).toBeVisible({ timeout: 15_000 });
    errors.assertNoFatalErrors();
  });

  test('edits and unsends a recent outgoing message via popup actions', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    // Single-token text keeps one semantics leaf so popup clicks hit inside the bubble
    const originalText = `Editable-${Date.now()}`;
    const post1 = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendTextReliably(page, originalText);
    await post1;
    await expect(msgLocator(page, originalText)).toBeVisible({ timeout: 15_000 });

    // Edit via popup -> inline MessageEditField
    await openMessagePopup(page, originalText, 'right');
    await clickPopupAction(page, 'Edit');

    const editField = page.getByRole('textbox', { name: 'Edited Message' }).first();
    await editField.waitFor({ state: 'attached', timeout: 10_000 });

    const editedText = `Updated-${Date.now()}`;
    let editSent = false;
    const editPromise = bbServer.waitForRequest('POST', /\/api\/v1\/message\/.*\/edit$/, 15_000).then((req) => {
      editSent = true;
      return req;
    });
    await expect(async () => {
      if (editSent) return;
      await editField.focus();
      const mod = process.platform === 'darwin' ? 'Meta' : 'Control';
      await page.keyboard.press(`${mod}+a`);
      await page.keyboard.press('Backspace');
      await page.keyboard.insertText(editedText);
      await expect(editField).toHaveValue(editedText, { timeout: 1_500 });
      await editField.focus();
      await page.keyboard.press('Enter');
      await expect.poll(() => editSent, { timeout: 2_000 }).toBe(true);
    }).toPass({ timeout: 12_000 });

    const editReq = await editPromise;
    expect(editReq.body?.editedMessage).toBe(editedText);
    await expect(msgLocator(page, editedText)).toBeVisible({ timeout: 15_000 });
    await expect(msgLocator(page, originalText)).toBeHidden({ timeout: 10_000 });

    // Send another fresh message and Undo Send it
    const toUnsendText = `Unsend-${Date.now()}`;
    const post2 = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendTextReliably(page, toUnsendText);
    await post2;
    await expect(msgLocator(page, toUnsendText)).toBeVisible({ timeout: 15_000 });

    await openMessagePopup(page, toUnsendText, 'right');
    const unsendPromise = bbServer.waitForRequest('POST', /\/api\/v1\/message\/.*\/unsend$/, 15_000);
    await clickPopupAction(page, 'Undo Send');
    await unsendPromise;

    await expect(
      page.getByLabel(/You unsent a message/i).or(page.getByText('You unsent a message', { exact: false })).first(),
    ).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });

  test('survives HTTP 500 send failure without uncaught errors and recovers on retry', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    bbServer.failNext('POST', '/api/v1/message/text', 500, { message: 'Simulated 500 error' });

    const failedText = `Fail500-${Date.now()}`;
    const failReqPromise = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendTextReliably(page, failedText);
    await failReqPromise;

    // App stays responsive with zero uncaught JS/Dart pageerrors
    expect(errors.pageErrors).toEqual([]);
    const nonHttpConsoleErrors = errors.consoleErrors.filter(
      (msg) => !msg.includes('status of 500') && !msg.includes('500'),
    );
    expect(nonHttpConsoleErrors).toEqual([]);

    // Next send succeeds normally
    const recoveryText = `Recovered-${Date.now()}`;
    const okReqPromise = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendTextReliably(page, recoveryText);
    const okReq = await okReqPromise;
    expect(okReq.body?.message).toBe(recoveryText);
    await expect(msgLocator(page, recoveryText)).toBeVisible({ timeout: 15_000 });
  });
});
