import * as net from 'node:net';
import {
  test,
  expect,
  bootFreshSetup,
  bootAuthenticated,
  enableSemantics,
  fillFlutterInput,
  openChat,
  waitForFlutterBoot,
} from '../fixtures/test';

async function getUnusedPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

test.describe('Setup, Initial Sync, Persistence & Reconnect Catch-Up', () => {
  test('SetupView validates bad password (401) and unreachable server, completes setup + sync, and persists across reload', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    test.setTimeout(90_000);

    await bootFreshSetup(page, pagesServer.url);

    // Page 1 (Welcome) -> Page 2 (MacSetupCheck)
    const nextBtn = page.getByRole('button', { name: 'Next' });
    await expect(nextBtn).toBeVisible();
    await nextBtn.click();

    // Page 2 (MacSetupCheck) -> Page 3 (ServerCredentials)
    await page.getByText('Setup Check', { exact: false }).waitFor({ state: 'visible' });
    await page.getByRole('button', { name: 'Next' }).last().click();
    await page
      .getByRole('button', { name: 'Connect' })
      .or(page.getByRole('button', { name: 'Manual entry' }))
      .first()
      .waitFor({ state: 'visible', timeout: 15_000 });

    // Expand manual entry if Google Sign-In buttons are shown
    const manualEntryBtn = page.getByRole('button', { name: 'Manual entry' });
    if (await manualEntryBtn.isVisible().catch(() => false)) {
      await manualEntryBtn.click();
    }

    const urlField = page.getByRole('textbox', { name: 'URL' }).or(page.getByLabel('URL')).first();
    const passField = page.getByRole('textbox', { name: 'Password' }).or(page.getByLabel('Password')).first();
    const connectBtn = page.getByRole('button', { name: 'Connect' });

    await expect(urlField).toBeAttached();
    await expect(passField).toBeAttached();

    // 1. Bad password -> 401 feedback
    await fillFlutterInput(page, urlField, bbServer.url);
    await fillFlutterInput(page, passField, 'wrong-password-999');
    await connectBtn.click();
    await expect(page.getByText('Authentication failed. Incorrect password!', { exact: false })).toBeVisible({
      timeout: 15_000,
    });

    // 2. Unreachable server -> connection error feedback
    const deadPort = await getUnusedPort();
    await fillFlutterInput(page, urlField, `http://127.0.0.1:${deadPort}`);
    await fillFlutterInput(page, passField, bbServer.password);
    await connectBtn.click();
    await expect(page.getByText('Failed to connect to', { exact: false })).toBeVisible({
      timeout: 15_000,
    });

    // Clear expected 401 / ERR_CONNECTION_REFUSED console errors from negative checks
    errors.clear();

    // 3. Valid URL + password -> full sync -> Finish -> ConversationList with seeded chats
    await fillFlutterInput(page, urlField, bbServer.url);
    await fillFlutterInput(page, passField, bbServer.password);
    await connectBtn.click();

    const finishBtn = page.getByRole('button', { name: 'Finish' });
    await finishBtn.waitFor({ state: 'visible', timeout: 30_000 });
    await finishBtn.click();

    // Dismiss Private API prompt if shown
    const privateApiBtn = page.getByRole('button', { name: 'Enable Private API Features' });
    if (await privateApiBtn.isVisible().catch(() => false)) {
      await privateApiBtn.click();
    }

    const firstChat = bbServer.seed.chats[0];
    const firstTitle = firstChat.displayName || firstChat.participants[0]?.address || 'Alex Mercer';
    await expect(page.getByText(firstTitle, { exact: false }).first()).toBeVisible({ timeout: 20_000 });

    // Verify localStorage + IndexedDB BlueBubblesStore.db persistence
    await expect
      .poll(
        () =>
          page.evaluate(
            () => localStorage.getItem('finishedSetup') ?? localStorage.getItem('flutter.finishedSetup'),
          ),
        { timeout: 10_000 },
      )
      .toBe('true');

    const persisted = await page.evaluate(async () => {
      const finishedSetup =
        localStorage.getItem('finishedSetup') ?? localStorage.getItem('flutter.finishedSetup');
      const serverAddress =
        localStorage.getItem('serverAddress') ?? localStorage.getItem('flutter.serverAddress');
      const guidAuthKey =
        localStorage.getItem('guidAuthKey') ?? localStorage.getItem('flutter.guidAuthKey');
      const dbs = typeof indexedDB.databases === 'function' ? await indexedDB.databases() : [];
      const hasStoreDb = dbs.some((d) => d.name === 'BlueBubblesStore.db');
      return { finishedSetup, serverAddress, guidAuthKey, hasStoreDb };
    });

    expect(persisted.finishedSetup).toBe('true');
    expect(persisted.serverAddress).toContain(bbServer.url);
    expect(persisted.guidAuthKey).toContain(bbServer.password);
    expect(persisted.hasStoreDb).toBe(true);

    // Reload page and confirm app boots directly into ConversationList with persisted chats
    await page.reload({ waitUntil: 'domcontentloaded' });
    await waitForFlutterBoot(page);
    await enableSemantics(page);
    await expect(page.getByText(firstTitle, { exact: false }).first()).toBeVisible({ timeout: 20_000 });
    await expect(page.getByText('Welcome to BlueBubbles', { exact: false })).toHaveCount(0);

    errors.assertNoFatalErrors();
  });

  test('recovers missed messages via incremental catch-up after socket disconnect and reconnect', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    test.setTimeout(90_000);

    await bootAuthenticated(page, pagesServer.url, bbServer);

    const firstChat = bbServer.seed.chats[0];
    const chatTitle = firstChat.displayName || firstChat.participants[0]?.address || 'Alex Mercer';
    await openChat(page, chatTitle);

    // Force socket disconnect and temporarily reject reconnects while adding an offline message
    bbServer.rejectSockets(true);
    bbServer.disconnectSockets(true);
    await expect.poll(() => bbServer.connectedSocketCount(), { timeout: 10_000 }).toBe(0);

    const missedText = `Missed while offline ${Date.now()}`;
    bbServer.addMessage(firstChat.guid, {
      text: missedText,
      isFromMe: false,
      dateCreated: Date.now(),
    });

    // Allow reconnect and wait for Socket.IO + catch-up sync to deliver the missed message
    bbServer.rejectSockets(false);
    await bbServer.waitForSocket(25_000);

    await expect(
      page.getByLabel(missedText, { exact: false }).or(page.getByText(missedText, { exact: false })).first(),
    ).toBeVisible({ timeout: 45_000 });

    errors.assertNoFatalErrors();
  });
});
