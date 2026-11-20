import { test, expect, bootFreshSetup, bootAuthenticated, openChat, sendMessage } from '../fixtures/test';

test.describe('BlueBubbles Web Smoke', () => {
  test('Wasm boots with crossOriginIsolated === true and 0 pageerrors', async ({ page, pagesServer, errors }) => {
    await bootFreshSetup(page, pagesServer.url);

    const isolated = await page.evaluate(() => window.crossOriginIsolated);
    expect(isolated).toBe(true);
    errors.assertNoFatalErrors();
  });

  test('SetupView renders "Welcome to BlueBubbles" with semantics active', async ({ page, pagesServer, errors }) => {
    await bootFreshSetup(page, pagesServer.url);

    await expect(page.getByText('Welcome to BlueBubbles', { exact: false })).toBeVisible();
    const semanticsCount = await page.evaluate(() => {
      let count = document.querySelectorAll('flt-semantics, [role]').length;
      for (const el of document.querySelectorAll('flutter-view, flt-glass-pane')) {
        if (el.shadowRoot) {
          count += el.shadowRoot.querySelectorAll('flt-semantics, [role]').length;
        }
      }
      return count;
    });
    expect(semanticsCount).toBeGreaterThan(0);
    errors.assertNoFatalErrors();
  });

  test('bootAuthenticated renders seeded chats, sends message, and receives live socket message', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer, { waitForSync: false });
    await page.waitForTimeout(3000);
    console.log('Requests:', bbServer.getRequests().map((r) => `${r.method} ${r.path}`));
    const labels = await page.evaluate(() => {
      const out: string[] = [];
      const walk = (root: ParentNode | ShadowRoot | null) => {
        if (!root) return;
        for (const el of root.querySelectorAll('flt-semantics')) {
          const lbl = el.getAttribute('aria-label') || el.textContent?.trim();
          if (lbl) out.push(lbl);
        }
        for (const h of root.querySelectorAll('flutter-view, flt-glass-pane')) {
          if (h.shadowRoot) walk(h.shadowRoot);
        }
      };
      walk(document);
      return out;
    });
    console.log('Semantics labels:', labels);

    // Open the first seeded chat (e.g. Alex Mercer or first chat in seed)
    const firstChat = bbServer.seed.chats[0];
    const chatTitle = firstChat.displayName || firstChat.participants[0]?.address || 'Alex';
    await openChat(page, chatTitle);

    // Send an outgoing message and verify POST /api/v1/message/text
    const outgoingText = `Smoke hello ${Date.now()}`;
    const postPromise = bbServer.waitForRequest('POST', '/api/v1/message/text', 15_000);
    await sendMessage(page, outgoingText);
    const req = await postPromise;
    expect(req.body?.message).toBe(outgoingText);
    await expect(page.getByText(outgoingText, { exact: false })).toBeVisible();

    // Emit a live incoming message via Socket.IO and verify it renders in real time
    const incomingText = `Live socket reply ${Date.now()}`;
    bbServer.emitNewMessage(firstChat.guid, {
      text: incomingText,
      isFromMe: false,
    });
    await expect(page.getByText(incomingText, { exact: false })).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });
});
