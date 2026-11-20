import {
  test,
  expect,
  bootAuthenticated,
  openChat,
  enableSemantics,
  waitForFlutterBoot,
} from '../fixtures/test';
import { makeHandle } from '../server/fixtures-data';

const GROUP_CHAT_GUID = 'iMessage;+;chat1000000000000001';

test.describe('Group Chats, Scheduled Messages & PWA Share Target', () => {
  test('renders group chat, opens desktop ChatInspectorPane, renames group, and applies live socket updates', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, /Weekend Crew/);

    const groupHeaderBtn = page.getByRole('button', { name: /Weekend Crew/ }).last();
    await expect(groupHeaderBtn).toBeVisible();

    const viewport = page.viewportSize();
    const isDesktopInspector = (viewport?.width ?? 0) > 1024;

    await groupHeaderBtn.click({ force: true });
    if (isDesktopInspector) {
      await expect(page.getByText('Details', { exact: true })).toBeVisible();
      await expect(
        page.getByRole('button', { name: 'Hide chat details (Alt+I)' }),
      ).toBeVisible();
    }

    // Participants in seeded groupChat should be rendered in inspector / details.
    await expect(
      page.getByText('Alex Mercer').or(page.getByLabel(/Alex Mercer/)).first(),
    ).toBeVisible();
    await expect(
      page.getByText('Jordan Lee').or(page.getByLabel(/Jordan Lee/)).first(),
    ).toBeVisible();

    // Rename group via UI -> PUT /api/v1/chat/:guid.
    const changeNameBtn = page.getByText(/Change Name|Add Name|Rename/).first();
    await expect(changeNameBtn).toBeVisible();
    await changeNameBtn.click();

    const privateApiBtn = page.getByRole('button', { name: 'Private API' });
    await privateApiBtn
      .waitFor({ state: 'visible', timeout: 5_000 })
      .then(() => privateApiBtn.click({ force: true }))
      .catch(() => {});

    const nameInput = page.getByRole('textbox', { name: 'Chat Name' });
    await expect(nameInput).toBeVisible();
    await nameInput.focus();
    await page.keyboard.press('End');
    for (let i = 0; i < 'Weekend Crew'.length + 4; i++) {
      await page.keyboard.press('Backspace');
    }
    await expect(nameInput).toHaveValue('');
    await nameInput.pressSequentially('Road Trip Crew');
    await expect(nameInput).toHaveValue('Road Trip Crew');

    const renameReqPromise = bbServer.waitForRequest(
      'PUT',
      /\/api\/v1\/chat\/.*chat1000000000000001/,
    );
    await page.getByRole('button', { name: 'OK' }).click();
    const renameReq = await renameReqPromise;
    expect(renameReq.body).toMatchObject({ displayName: 'Road Trip Crew' });
    await expect(page.getByText('Road Trip Crew', { exact: true }).first()).toBeVisible();

    // Live socket updates: group-name-change, participant-added, participant-removed.
    bbServer.emitGroupNameChange(GROUP_CHAT_GUID, 'Alpine Squad');
    await expect(page.getByText('Alpine Squad', { exact: true }).first()).toBeVisible({
      timeout: 10_000,
    });

    const extraHandle = makeHandle({
      address: '+15550100099',
      formattedAddress: '(555) 010-0099',
    });
    const extraParticipant = page
      .getByText('(555) 010-0099')
      .or(page.getByLabel(/\(555\) 010-0099/))
      .first();
    bbServer.emitParticipantEvent('participant-added', GROUP_CHAT_GUID, extraHandle);
    await expect(extraParticipant).toBeVisible({ timeout: 10_000 });
    bbServer.emitParticipantEvent('participant-removed', GROUP_CHAT_GUID, extraHandle);
    await expect(extraParticipant).not.toBeVisible({ timeout: 10_000 });

    errors.assertNoFatalErrors();
  });

  test('schedules a message via composer Schedule flow', async ({
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

    const scheduleTile = page.getByText('Schedule').first();
    await expect(scheduleTile).toBeVisible();
    await scheduleTile.click();

    const oneHourOption = page.getByText('1 Hour');
    await expect(oneHourOption).toBeVisible();
    await oneHourOption.click();

    const semanticsComposer = page
      .locator('textarea[data-semantics-role="text-field"]')
      .last();
    await expect(semanticsComposer).toBeVisible();
    await semanticsComposer.focus();
    await semanticsComposer.pressSequentially('Scheduled ping');
    await expect(semanticsComposer).toHaveValue('Scheduled ping');

    const scheduleReqPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/message/schedule',
    );
    await page.keyboard.press('Enter');

    const scheduleReq = await scheduleReqPromise;
    expect(JSON.stringify(scheduleReq.body)).toContain('Scheduled ping');

    errors.assertNoFatalErrors();
  });

  test('handles PWA Share Target query parameters without fatal errors', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    // Seed authenticated state first, then boot with PWA share_target params.
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const shareUrl = `${pagesServer.url}/?title=Shared+Note&text=Check+this+out&url=${encodeURIComponent('https://example.com')}`;
    await page.goto(shareUrl, { waitUntil: 'domcontentloaded' });
    await waitForFlutterBoot(page);
    await enableSemantics(page);

    await expect(page.getByText(/New Message|New chat/)).toBeVisible({ timeout: 20_000 });
    // Select Alex Mercer from NewChatCreator's Conversations list so initialText
    // transfers into the active chat composer, then send it to verify the payload.
    const alexEntry = page.getByRole('button', { name: /Alex Mercer \+1 \(555\) 010-0001/ });
    await expect(alexEntry).toBeVisible({ timeout: 10_000 });
    await alexEntry.click();

    const sendReqPromise = bbServer.waitForRequest('POST', '/api/v1/message/text');
    const composer = page.getByRole('textbox').last();
    await expect(composer).toBeVisible({ timeout: 10_000 });
    await composer.click({ force: true });
    await page.keyboard.press('Enter');

    const sendReq = await sendReqPromise;
    expect(JSON.stringify(sendReq.body)).toContain('Shared Note');
    expect(JSON.stringify(sendReq.body)).toContain('Check this out');
    expect(JSON.stringify(sendReq.body)).toContain('https://example.com');

    errors.assertNoFatalErrors();
  });
});
