import {
  test,
  expect,
  bootAuthenticated,
  fillFlutterInput,
} from '../fixtures/test';
import type { Page } from '@playwright/test';

const SMS_GUID = 'SMS;-;+15550100002';
const DM_GUID = 'iMessage;-;+15550100001';
const GROUP_GUID = 'iMessage;+;chat1000000000000001';

function tileLocator(page: Page, title: string | RegExp) {
  return page
    .getByRole('button', { name: title })
    .or(page.getByLabel(title))
    .or(page.getByText(title))
    .first();
}

function menuItemLocator(page: Page, name: string) {
  return page
    .getByRole('menuitem', { name, exact: true })
    .or(page.getByText(name, { exact: true }))
    .first();
}

async function dismissMenu(page: Page) {
  const dismissBtn = page.getByRole('button', { name: 'Dismiss menu' }).first();
  if (await dismissBtn.isVisible().catch(() => false)) {
    await dismissBtn.click({ force: true });
    await expect(dismissBtn).toBeHidden({ timeout: 5_000 });
    return;
  }
  await page.keyboard.press('Escape');
}

async function openTileContextMenu(page: Page, title: string) {
  const tile = tileLocator(page, title);
  await tile.waitFor({ state: 'visible', timeout: 15_000 });
  await tile.click({ button: 'right', force: true });
}

async function ensureListVisible(page: Page) {
  const searchPill = page
    .getByRole('group', { name: /Search BlueBubbles/i })
    .or(page.getByLabel(/Search BlueBubbles/i))
    .or(page.getByText('Search BlueBubbles', { exact: false }))
    .first();
  if (await searchPill.isVisible().catch(() => false)) {
    return;
  }
  await expect(async () => {
    if (await searchPill.isVisible().catch(() => false)) {
      return;
    }
    const namedBack = page.getByRole('button', { name: 'Back' }).first();
    if (await namedBack.isVisible().catch(() => false)) {
      await namedBack.click({ force: true });
    }
    await expect(searchPill).toBeVisible({ timeout: 1_500 });
  }).toPass({ timeout: 15_000 });
}

test.describe('Conversation List', () => {
  test('renders seeded 1:1, SMS unread, pinned, and group chats with context menu state', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    await expect(tileLocator(page, 'Alex Mercer')).toBeVisible();
    await expect(tileLocator(page, /Jordan Lee.*Unread SMS update: package arrives at 3pm\./)).toBeVisible();
    await expect(tileLocator(page, /Weekend Crew.*I got the chips and salsa covered!/)).toBeVisible();

    // Seeded Alex Mercer is pinned -> menu offers Unpin
    await openTileContextMenu(page, 'Alex Mercer');
    await expect(menuItemLocator(page, 'Unpin')).toBeVisible({ timeout: 10_000 });
    await dismissMenu(page);

    // Seeded Jordan Lee is unread -> menu offers Mark Read
    await openTileContextMenu(page, 'Jordan Lee');
    await expect(menuItemLocator(page, 'Mark Read')).toBeVisible({ timeout: 10_000 });
    await dismissMenu(page);

    errors.assertNoFatalErrors();
  });

  test('opening unread chat sends POST /read', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer, {
      extraStorage: { privateMarkChatAsRead: true },
    });

    const readReqPromise = bbServer.waitForRequest('POST', /\/api\/v1\/chat\/.*\/read$/, 15_000);
    await expect(async () => {
      await tileLocator(page, 'Jordan Lee').click({ force: true });
      await expect(page.getByRole('textbox', { name: 'Text message' }).first()).toBeAttached({
        timeout: 2_000,
      });
    }).toPass({ timeout: 15_000 });
    const readReq = await readReqPromise;
    expect(decodeURIComponent(readReq.path)).toBe(`/api/v1/chat/${SMS_GUID}/read`);

    errors.assertNoFatalErrors();
  });

  test('Mark Unread sends POST /unread', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    await page.evaluate(() => {
      window.location.hash = '#/settings';
    });
    if ((page.viewportSize()?.width ?? 0) > 680) {
      await expect(page.getByText('Server Management').first()).toBeVisible({ timeout: 15_000 });
    }
    const searchSettings = page.getByRole('searchbox', { name: 'Search Settings' }).first();
    await expect(searchSettings).toBeVisible({ timeout: 15_000 });
    await searchSettings.click({ force: true });
    await page.keyboard.type('Automatic Mark Read', { delay: 10 });
    const searchResultBtn = page.getByRole('button', { name: /Automatic Mark Read/i }).first();
    await expect(searchResultBtn).toBeVisible({ timeout: 10_000 });
    const manualSwitch = page.getByRole('group', { name: /Manual Mark Read/i }).getByRole('switch').first();
    await expect(async () => {
      await searchResultBtn.click({ force: true });
      await expect(manualSwitch).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });

    if (!(await manualSwitch.isChecked())) {
      await manualSwitch.click({ force: true });
    }
    await expect(manualSwitch).toBeChecked({ timeout: 10_000 });

    await expect(async () => {
      const backBtn = page.getByRole('button', { name: 'Back' }).first();
      if (await backBtn.isVisible().catch(() => false)) {
        await backBtn.click({ force: true });
      }
      await expect(tileLocator(page, 'Weekend Crew')).toBeVisible({ timeout: 1_500 });
    }).toPass({ timeout: 15_000 });

    // Open Alex Mercer (1:1 iMessage) -> Show menu -> Details -> disable Automatically send read receipts
    await tileLocator(page, 'Alex Mercer').click({ force: true });
    const showMenuBtn = page.getByRole('button', { name: 'Show menu' }).first();
    await expect(showMenuBtn).toBeVisible({ timeout: 15_000 });
    const detailsMenuItem = page.getByRole('menuitem', { name: 'Details', exact: true }).first();
    await expect(async () => {
      if (!(await detailsMenuItem.isVisible().catch(() => false))) {
        await showMenuBtn.click({ force: true });
      }
      await expect(detailsMenuItem).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 10_000 });
    await detailsMenuItem.click({ force: true });

    const autoReadSwitch = page.getByRole('switch', { name: /Automatically send read receipts/i }).first();
    await expect(async () => {
      if (!(await autoReadSwitch.isVisible().catch(() => false))) {
        const anchor = page.getByText('Conversation', { exact: true }).first();
        const box = await anchor.boundingBox().catch(() => null);
        if (box) {
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          await page.mouse.wheel(0, 300);
        }
      }
      await expect(autoReadSwitch).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });
    await expect(async () => {
      if (await autoReadSwitch.isChecked()) {
        await autoReadSwitch.click({ force: true });
      }
      await expect(autoReadSwitch).not.toBeChecked({ timeout: 1_500 });
    }).toPass({ timeout: 10_000 });

    // Return to list (if pushed) and reopen Alex Mercer fresh so ManualMark reads autoSendReadReceipts = false
    const detailsBack = page.getByRole('button', { name: 'Back' }).first();
    if (await detailsBack.isVisible().catch(() => false)) {
      await detailsBack.click({ force: true });
    }
    await ensureListVisible(page);
    if ((page.viewportSize()?.width ?? 0) > 680) {
      await tileLocator(page, 'Weekend Crew').click({ force: true });
    }
    await tileLocator(page, 'Alex Mercer').click({ force: true });

    const markReadBtn = page.getByRole('button', { name: 'Mark Read' });
    const markUnreadBtn = page.getByRole('button', { name: 'Mark Unread' });
    await expect(markReadBtn).toBeVisible({ timeout: 15_000 });
    const manualReadPromise = bbServer.waitForRequest('POST', /\/api\/v1\/chat\/.*\/read$/, 15_000);
    await expect(async () => {
      if (await markReadBtn.isVisible().catch(() => false)) {
        await markReadBtn.click({ force: true });
      }
      await expect(markUnreadBtn).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });
    await manualReadPromise;

    const unreadReqPromise = bbServer.waitForRequest('POST', /\/api\/v1\/chat\/.*\/unread$/, 15_000);
    await expect(async () => {
      if (await markUnreadBtn.isVisible().catch(() => false)) {
        await markUnreadBtn.click({ force: true });
      }
      await expect(markReadBtn).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });
    const unreadReq = await unreadReqPromise;
    expect(decodeURIComponent(unreadReq.path)).toBe(`/api/v1/chat/${DM_GUID}/unread`);

    errors.assertNoFatalErrors();
  });

  test('updates conversation list on chat-read-status-changed, pinned-chats-updated, and group-name-change events', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    // 1. Live chat-read-status-changed: mark Jordan Lee read and Alex Mercer unread
    bbServer.emitChatReadStatus(SMS_GUID, true);
    await expect(async () => {
      await openTileContextMenu(page, 'Jordan Lee');
      try {
        await expect(menuItemLocator(page, 'Mark Unread')).toBeVisible({ timeout: 1_500 });
      } finally {
        await dismissMenu(page);
      }
    }).toPass({ timeout: 15_000 });

    bbServer.emitChatReadStatus(DM_GUID, false);
    await expect(async () => {
      await openTileContextMenu(page, 'Alex Mercer');
      try {
        await expect(menuItemLocator(page, 'Mark Read')).toBeVisible({ timeout: 1_500 });
      } finally {
        await dismissMenu(page);
      }
    }).toPass({ timeout: 15_000 });

    // 2. Live pinned-chats-updated: pin Weekend Crew and unpin Alex Mercer
    bbServer.emitPinnedChats([GROUP_GUID]);
    await expect(async () => {
      await openTileContextMenu(page, 'Weekend Crew');
      try {
        await expect(menuItemLocator(page, 'Unpin')).toBeVisible({ timeout: 1_500 });
      } finally {
        await dismissMenu(page);
      }
    }).toPass({ timeout: 15_000 });

    // 3. Live group-name-change: triggers GET /api/v1/chat/:guid and persists new title
    const fetchChatPromise = bbServer.waitForRequest(
      'GET',
      /\/api\/v1\/chat\/.*chat1000000000000001$/,
      15_000,
    );
    bbServer.emitGroupNameChange(GROUP_GUID, 'Mountain Trip');
    await fetchChatPromise;
    await expect(tileLocator(page, 'Mountain Trip')).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });

  test('searches messages from "Search BlueBubbles" and displays matching results', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const searchPill = page
      .getByRole('group', { name: /Search BlueBubbles/i })
      .or(page.getByLabel(/Search BlueBubbles/i))
      .or(page.getByText('Search BlueBubbles', { exact: false }))
      .first();
    await searchPill.waitFor({ state: 'visible', timeout: 15_000 });

    const searchInput = page
      .getByRole('textbox', { name: 'Search messages' })
      .or(page.getByLabel('Search messages'))
      .or(page.getByRole('textbox'))
      .first();

    // Click inside the left text area of the search pill (avoiding the right-edge account button)
    await expect(async () => {
      const box = await searchPill.boundingBox();
      if (box) {
        await page.mouse.click(box.x + Math.min(90, box.width * 0.35), box.y + box.height / 2);
      } else {
        await searchPill.click({ force: true });
      }
      await expect(searchInput).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 15_000 });

    const queryPromise = bbServer.waitForRequest('POST', '/api/v1/message/query', 15_000);
    await fillFlutterInput(page, searchInput, 'package');
    await page.keyboard.press('Enter');
    const queryReq = await queryPromise;
    expect(JSON.stringify(queryReq.body ?? {})).toContain('package');

    await expect(tileLocator(page, /Jordan Lee/)).toBeVisible({ timeout: 15_000 });
    await expect(tileLocator(page, /Unread SMS update: package arrives at 3pm\./)).toBeVisible({
      timeout: 15_000,
    });

    errors.assertNoFatalErrors();
  });

  test('creates a new chat via Start chat flow and sends initial message', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const startChatBtn = page
      .getByRole('button', { name: /Start chat/i })
      .or(page.getByLabel(/Start chat/i))
      .or(page.getByText('Start chat', { exact: false }))
      .first();
    await startChatBtn.waitFor({ state: 'visible', timeout: 15_000 });
    await startChatBtn.click({ force: true });

    await expect(
      page.getByRole('heading', { name: 'New chat' }).or(page.getByText('New chat', { exact: false })).first(),
    ).toBeVisible({ timeout: 15_000 });

    const recipientInput = page
      .getByRole('textbox', { name: /Name, phone number, or group/i })
      .or(page.getByLabel(/Name, phone number, or group/i))
      .first();
    await fillFlutterInput(page, recipientInput, '+15550109999');

    const sendToOption = page
      .getByRole('button', { name: /Send to "\+15550109999"/i })
      .or(page.getByText('Send to "+15550109999"', { exact: false }))
      .first();
    await sendToOption.waitFor({ state: 'visible', timeout: 10_000 });
    await sendToOption.click({ force: true });
    await expect(sendToOption).toBeHidden({ timeout: 10_000 });

    // Target the message composer specifically (the recipient textbox remains mounted above it)
    const composer = page
      .getByRole('textbox', { name: /^(Text message|iMessage|New Message|Text Message|Message)$/i })
      .last();
    await composer.waitFor({ state: 'visible', timeout: 10_000 });

    let newChatSent = false;
    const newChatReqPromise = bbServer.waitForRequest('POST', '/api/v1/chat/new', 15_000).then((req) => {
      newChatSent = true;
      return req;
    });
    await expect(async () => {
      if (newChatSent) return;
      await composer.click({ force: true });
      const mod = process.platform === 'darwin' ? 'Meta' : 'Control';
      await page.keyboard.press(`${mod}+a`);
      await page.keyboard.press('Backspace');
      await page.keyboard.insertText('Hello new recipient');
      await expect(composer).toHaveValue('Hello new recipient', { timeout: 1_500 });
      // NewChatCreator sets keyboardHandler=null for unsaved recipients; Send button has no aria-label.
      const sendBtn = page.locator('flt-semantics[role="button"]:not([aria-label])').last();
      await sendBtn.waitFor({ state: 'visible', timeout: 2_000 });
      await sendBtn.click({ force: true });
      await expect.poll(() => newChatSent, { timeout: 2_000 }).toBe(true);
    }).toPass({ timeout: 12_000 });

    const newChatReq = await newChatReqPromise;
    expect(newChatReq.body?.addresses).toContain('+15550109999');
    expect(newChatReq.body?.message).toBe('Hello new recipient');

    await expect(
      page.getByLabel('Hello new recipient', { exact: false }).or(page.getByText('Hello new recipient')).first(),
    ).toBeVisible({ timeout: 15_000 });

    expect(errors.pageErrors).toEqual([]);
    const non404ConsoleErrors = errors.consoleErrors.filter((msg) => !msg.includes('404'));
    expect(non404ConsoleErrors).toEqual([]);
  });
});
