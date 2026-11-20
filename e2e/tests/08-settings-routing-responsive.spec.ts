import {
  test,
  expect,
  bootAuthenticated,
  enableSemantics,
  openChat,
  waitForFlutterBoot,
} from '../fixtures/test';

const ALEX_GUID = 'iMessage;-;+15550100001';
const SEEDED_ALEX_MSG = 'Hey! Ready for the BlueBubbles E2E test?';

async function clickStableLocator(locator: import('@playwright/test').Locator): Promise<void> {
  await expect(locator).toBeVisible({ timeout: 15_000 });
  let prev: { x: number; y: number; width: number; height: number } | null = null;
  await expect(async () => {
    const box = await locator.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThan(10);
    expect(box!.height).toBeGreaterThan(10);
    if (!prev || Math.abs(box!.x - prev.x) > 1 || Math.abs(box!.y - prev.y) > 1) {
      prev = box;
      throw new Error('Wait for layout/scroll to settle');
    }
  }).toPass({ timeout: 5_000, intervals: [100] });
  await locator.click({ force: true });
}

async function openSettings(page: import('@playwright/test').Page): Promise<void> {
  await page.evaluate(() => {
    window.location.hash = '#/settings';
  });
  await expect(page.getByText('Appearance Settings').first()).toBeVisible({ timeout: 15_000 });
  if ((page.viewportSize()?.width ?? 0) > 680) {
    // Wait for SettingsPage.initState post-frame ServerManagementPanel push to settle
    await expect(page.getByText('Server Management').first()).toBeVisible({ timeout: 15_000 });
  }
}

test.describe('Settings, Hash Routing, Shortcuts & Responsive Layouts', () => {
  test('supports hash routes (#/, #/settings, #/chat/<encodedGuid>) and updates URL hash on chat open', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    // 1. Navigate to #/settings via hash URL
    await openSettings(page);
    await expect(page.getByText('Settings').first()).toBeVisible();

    // 2. Navigate to #/chat/<encodedGuid> via hash URL
    const encodedGuid = encodeURIComponent(ALEX_GUID);
    await page.evaluate((hash) => {
      window.location.hash = hash;
    }, `#/chat/${encodedGuid}`);

    await expect(
      page.getByText(SEEDED_ALEX_MSG, { exact: false }).first(),
    ).toBeVisible({ timeout: 15_000 });

    // 3. Navigate back to #/ root (mobile uses Back button since closeAllConversationView only pops _right)
    if ((page.viewportSize()?.width ?? 0) > 680) {
      await page.evaluate(() => {
        window.location.hash = '#/';
      });
      await expect
        .poll(() => page.evaluate(() => window.location.hash), { timeout: 10_000 })
        .toMatch(/^(#\/)?$/);
    } else {
      const backBtn = page.getByRole('button', { name: 'Back' }).first();
      if (await backBtn.isVisible().catch(() => false)) {
        await backBtn.click({ force: true });
      } else {
        await page.locator('flt-semantics[role="button"]:not([aria-label])').first().click({ force: true });
      }
    }
    await expect(page.getByText('Weekend Crew').first()).toBeVisible({ timeout: 15_000 });

    // 4. Opening a chat from the list syncs the URL hash to #/chat/<encodedGuid>
    await openChat(page, 'Jordan Lee');
    await expect
      .poll(() => page.evaluate(() => window.location.hash), { timeout: 10_000 })
      .toContain('#/chat/');

    errors.assertNoFatalErrors();
  });

  test('renders Settings sections and persists toggled preferences in localStorage across reload', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openSettings(page);

    // Verify major Web Settings sections are rendered
    for (const sectionTitle of [
      'Profile',
      'Connection & Server',
      'Appearance Settings',
      'Notification Settings',
      'Chat List Settings',
      'Conversation Settings',
    ]) {
      await expect(page.getByText(sectionTitle).first()).toBeVisible();
    }

    // Filter Settings via Search Settings to jump straight to Chat List -> Show Sync Indicator in Chat List
    const searchSettings = page.getByRole('searchbox', { name: 'Search Settings' }).first();
    await searchSettings.click({ force: true });
    await page.keyboard.type('Show Sync Indicator', { delay: 10 });

    const searchResultBtn = page.getByRole('button', { name: /Show Sync Indicator in Chat List/i }).first();
    await expect(searchResultBtn).toBeVisible({ timeout: 10_000 });
    await clickStableLocator(searchResultBtn);

    const syncGroup = page.getByRole('group', { name: /Show Sync Indicator in Chat List/i }).first();
    await expect(syncGroup).toBeVisible({ timeout: 10_000 });
    const syncSwitch = syncGroup.getByRole('switch').first();
    await expect(syncSwitch).toBeVisible({ timeout: 10_000 });

    const beforeChecked = await syncSwitch.isChecked();
    const expectedNext = beforeChecked ? 'false' : 'true';
    await syncSwitch.click({ force: true });

    await expect
      .poll(
        () =>
          page.evaluate(
            () => localStorage.getItem('showSyncIndicator') ?? localStorage.getItem('flutter.showSyncIndicator'),
          ),
        { timeout: 10_000 },
      )
      .toBe(expectedNext);

    // Reload and confirm preference remains persisted in localStorage
    await page.reload({ waitUntil: 'domcontentloaded' });
    await waitForFlutterBoot(page);
    await enableSemantics(page);

    const afterReload = await page.evaluate(
      () => localStorage.getItem('showSyncIndicator') ?? localStorage.getItem('flutter.showSyncIndicator'),
    );
    expect(afterReload).toBe(expectedNext);

    errors.assertNoFatalErrors();
  });

  test('handles keyboard shortcuts (Ctrl/Cmd+K, Ctrl+F, Alt+N, Alt+I on desktop, Escape dismiss)', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    // Ensure Flutter canvas/window has keyboard focus without clicking the top-left Search icon
    const viewport = page.viewportSize();
    if ((viewport?.width ?? 0) > 680) {
      await page.getByText('Keep every chat going').first().click({ force: true });
    } else {
      await page.locator('flutter-view, flt-glass-pane').first().click({ position: { x: 200, y: 20 }, force: true });
    }

    // Alt+I -> toggles ChatInspectorPane on desktop (width > 1024; hidden by default on Web)
    if ((viewport?.width ?? 0) > 1024) {
      await openChat(page, 'Alex Mercer');
      await expect(page.getByRole('button', { name: 'Hide chat details (Alt+I)' })).toHaveCount(0);

      await page.keyboard.press('Alt+i');
      await expect(page.getByRole('button', { name: 'Hide chat details (Alt+I)' })).toBeVisible({
        timeout: 10_000,
      });

      await page.keyboard.press('Alt+i');
      await expect(page.getByRole('button', { name: 'Hide chat details (Alt+I)' })).toHaveCount(0, {
        timeout: 10_000,
      });
    }

    const dismissOverlay = async () => {
      if (viewport && viewport.width <= 680) {
        const backBtn = page.getByRole('button', { name: /Back/i }).first();
        await clickStableLocator(backBtn);
      } else {
        await page.keyboard.press('Escape');
      }
    };

    // Ctrl+K -> NewChatCreator, dismiss
    await page.keyboard.press('Control+k');
    const newChatTitle = page.getByText(/New chat|New Message/i).first();
    await expect(newChatTitle).toBeVisible({ timeout: 10_000 });
    await dismissOverlay();
    await expect(page.getByText(/New chat|New Message/i)).toHaveCount(0, { timeout: 10_000 });

    // Alt+N -> NewChatCreator, dismiss
    await page.keyboard.press('Alt+n');
    await expect(newChatTitle).toBeVisible({ timeout: 10_000 });
    await dismissOverlay();
    await expect(page.getByText(/New chat|New Message/i)).toHaveCount(0, { timeout: 10_000 });

    // Ctrl+F -> SearchView, dismiss (on desktop/tablet Escape pops back to chat list)
    await page.keyboard.press('Control+f');
    const searchHint = page.getByText('Enter at least 3 characters to begin a search', { exact: false }).first();
    await expect(searchHint).toBeVisible({ timeout: 10_000 });
    if (!viewport || viewport.width > 680) {
      await dismissOverlay();
      await expect(page.getByText('Alex Mercer').first()).toBeVisible({ timeout: 10_000 });
    }

    errors.assertNoFatalErrors();
  });

  test('adapts layout across desktop (1440x900), tablet (900x800), and mobile (390x844)', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }, testInfo) => {
    // Run the multi-viewport responsive sweep once under the desktop project to avoid 3x duplicate runs
    test.skip(testInfo.project.name !== 'desktop', 'Multi-viewport sweep runs once under desktop project');

    await page.setViewportSize({ width: 1440, height: 900 });
    await bootAuthenticated(page, pagesServer.url, bbServer);

    // Desktop (1440x900): split pane (list + active chat) + inspector toggle via Alt+I
    await openChat(page, 'Alex Mercer');
    await expect(page.getByText('Weekend Crew').first()).toBeVisible();
    await expect(page.getByText(SEEDED_ALEX_MSG, { exact: false }).first()).toBeVisible();
    await page.keyboard.press('Alt+i');
    await expect(page.getByRole('button', { name: 'Hide chat details (Alt+I)' })).toBeVisible({
      timeout: 10_000,
    });

    // Tablet (900x800): split pane stays active (width > 680), inspector pane hides (width <= 1024)
    await page.setViewportSize({ width: 900, height: 800 });
    await expect(page.getByText('Weekend Crew').first()).toBeVisible({ timeout: 10_000 });
    await expect(page.getByText(SEEDED_ALEX_MSG, { exact: false }).first()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Hide chat details (Alt+I)' })).toHaveCount(0);

    // Mobile (390x844): single-pane back to list -> open chat -> back to list
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByText('Weekend Crew').first()).not.toBeVisible({ timeout: 10_000 });
    const goBackMobile = async () => {
      const namedBack = page.getByRole('button', { name: 'Back' }).first();
      if (await namedBack.isVisible().catch(() => false)) {
        await namedBack.click({ force: true });
        return;
      }
      const unnamedBack = page.locator('flt-semantics[role="button"]:not([aria-label])').first();
      if (await unnamedBack.isVisible().catch(() => false)) {
        await unnamedBack.click({ force: true });
        return;
      }
      await page.keyboard.press('Escape');
    };
    await goBackMobile();

    await expect(page.getByText('Weekend Crew').first()).toBeVisible({ timeout: 15_000 });
    await page.getByText('Alex Mercer').first().click({ force: true });

    await expect(page.getByText(SEEDED_ALEX_MSG, { exact: false }).first()).toBeVisible({
      timeout: 15_000,
    });
    // List item for another conversation is offstage on single-pane mobile
    await expect(page.getByText('Jordan Lee')).not.toBeVisible();

    // Back returns to conversation list
    await goBackMobile();
    await expect(page.getByText('Weekend Crew').first()).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });
});
