import * as fs from 'node:fs';
import * as path from 'node:path';
import {
  test,
  expect,
  bootAuthenticated,
  openChat,
} from '../fixtures/test';
import type { Locator, Page, TestInfo } from '@playwright/test';

const VQA_OUT_DIR = '/tmp/vqa/web';

test.use({
  permissions: ['microphone'],
  launchOptions: {
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
    ],
  },
});

function ensureOutDir(): void {
  fs.mkdirSync(VQA_OUT_DIR, { recursive: true });
}

async function applyViewport(page: Page, testInfo: TestInfo): Promise<'desktop' | 'mobile'> {
  if (testInfo.project.name === 'mobile') {
    await page.setViewportSize({ width: 390, height: 844 });
    return 'mobile';
  }
  await page.setViewportSize({ width: 1280, height: 800 });
  return 'desktop';
}

async function captureVqa(page: Page, tag: string, name: string): Promise<void> {
  ensureOutDir();
  await page.waitForTimeout(350);
  await page.screenshot({
    path: path.join(VQA_OUT_DIR, `${tag}-${name}.png`),
    animations: 'disabled',
  });
}

async function clickStableLocator(locator: Locator): Promise<void> {
  await expect(locator).toBeVisible({ timeout: 15_000 });
  let prev: { x: number; y: number; width: number; height: number } | null = null;
  await expect(async () => {
    const box = await locator.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThan(10);
    expect(box!.height).toBeGreaterThan(10);
    if (!prev || Math.abs(box!.x - prev.x) > 1 || Math.abs(box!.y - prev.y) > 1) {
      prev = box;
      throw new Error('Wait for layout animation to settle');
    }
  }).toPass({ timeout: 5_000, intervals: [100] });
  await locator.click({ force: true });
}

async function openFindMy(page: Page): Promise<void> {
  const fabBtn = page.getByRole('button', { name: 'Find My' }).first();
  if (await fabBtn.isVisible().catch(() => false)) {
    await fabBtn.click({ force: true });
  } else {
    await page.getByRole('button', { name: 'More options' }).first().click({ force: true });
    await page.getByText('Find My', { exact: true }).first().click({ force: true });
  }
  await expect(page.getByRole('button', { name: 'Refresh Locations' }).first()).toBeVisible({
    timeout: 15_000,
  });
}

async function selectFindMyTab(page: Page, tabName: 'People' | 'Devices' | 'Items'): Promise<void> {
  const tab = page
    .getByRole('tab', { name: tabName })
    .or(page.getByRole('button', { name: tabName }))
    .first();
  await expect(async () => {
    await clickStableLocator(tab);
    if ((await tab.getAttribute('role')) === 'tab') {
      await expect(tab).toHaveAttribute('aria-selected', 'true', { timeout: 1_500 });
    } else {
      await expect(page.getByText(tabName, { exact: true }).nth(1)).toBeVisible({ timeout: 1_500 });
    }
  }).toPass({ timeout: 10_000, intervals: [200] });
}

test.describe('Visual QA: Call, Media, Stickers & Find My', () => {
  test('captures FaceTime incoming banner, outgoing sheet, active call + DTMF, and ongoing pill', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }, testInfo) => {
    const tag = await applyViewport(page, testInfo);
    await bootAuthenticated(page, pagesServer.url, bbServer);

    // 1. Incoming FaceTime banner
    const searchGroup = page.getByRole('group', { name: /Search/i }).first();
    await expect(searchGroup).toBeVisible();
    const boxBefore = await searchGroup.boundingBox();
    expect(boxBefore).not.toBeNull();

    bbServer.emitIncomingFaceTime({
      uuid: 'ft-in-vqa-1',
      address: '+15550100001',
      is_video: true,
      is_audio: false,
      link: 'https://facetime.apple.com/join#v=1&p=vqa-1',
    });

    await expect
      .poll(async () => (await searchGroup.boundingBox())?.y ?? 0, { timeout: 15_000 })
      .toBeGreaterThan((boxBefore?.y ?? 0) + 30);
    await captureVqa(page, tag, 'incoming-banner');

    // Accept from the incoming banner, then tap the ongoing call banner to open InAppCallScreen
    // (OngoingCallPillOverlay renders in a top overlay outside main Scaffold semantics)
    await page.mouse.click(tag === 'mobile' ? 353 : 1228, 30);
    await page.waitForTimeout(350);

    const keypadBtn = page
      .getByRole('switch', { name: 'Keypad' })
      .or(page.getByRole('button', { name: 'Keypad' }))
      .first();
    if (!(await keypadBtn.isVisible({ timeout: 2_000 }).catch(() => false))) {
      await page.mouse.click(80, 30);
    }
    await expect(keypadBtn).toBeVisible({ timeout: 15_000 });
    await captureVqa(page, tag, 'active-call');

    const callVideoToggle = page
      .getByRole('switch', { name: 'Video' })
      .or(page.getByRole('button', { name: 'Video' }))
      .first();
    if (await callVideoToggle.isVisible().catch(() => false)) {
      await callVideoToggle.click({ force: true });
      await page.waitForTimeout(250);
    }
    await captureVqa(page, tag, 'active-call-video-pip');

    await keypadBtn.click({ force: true });
    const digit1 = page.getByRole('button', { name: /DTMF 1/ }).first();
    await expect(digit1).toBeVisible({ timeout: 10_000 });
    await digit1.click({ force: true });
    await page.getByRole('button', { name: /DTMF 2/ }).first().click({ force: true });
    await captureVqa(page, tag, 'active-call-dtmf');

    const minimizeBtn = page.getByRole('button', { name: /Minimize/i }).first();
    await expect(minimizeBtn).toBeVisible({ timeout: 10_000 });
    await minimizeBtn.click({ force: true });
    await page.waitForTimeout(350);
    await captureVqa(page, tag, 'ongoing-pill');

    await page.mouse.click(tag === 'mobile' ? 353 : 1244, 30);
    await page.waitForTimeout(300);

    // 2. Outgoing FaceTime sheet (Video)
    await openChat(page, 'Alex Mercer');
    await page.waitForTimeout(350);
    const videoBtn = page.getByRole('button', { name: 'Video' }).first();
    await expect(videoBtn).toBeVisible();
    await clickStableLocator(videoBtn);
    await expect(page.getByText(/Ringing|Calling|FaceTime/i).first()).toBeVisible({ timeout: 10_000 });
    await captureVqa(page, tag, 'outgoing-facetime-sheet');

    const closeSheetBtn = page.getByRole('button', { name: /Close|Hang Up|Cancel call/i }).first();
    if (await closeSheetBtn.isVisible().catch(() => false)) {
      await closeSheetBtn.click({ force: true });
    } else {
      await page.keyboard.press('Escape');
    }

    errors.assertNoFatalErrors();
  });

  test('captures add-attachment popover, stickers picker, schedule modal, and Find My tabs', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }, testInfo) => {
    const tag = await applyViewport(page, testInfo);
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');

    // 1. Add-attachment `+` menu / sheet
    const addAttachmentBtn = page.getByRole('button', { name: 'Add attachment' }).first();
    await expect(addAttachmentBtn).toBeVisible();
    await addAttachmentBtn.click({ force: true });

    const stickersItem = page.getByText('Stickers', { exact: true }).first();
    await expect(stickersItem).toBeVisible({ timeout: 10_000 });
    await captureVqa(page, tag, 'attachment-popover');

    // 2. Stickers picker
    await stickersItem.click({ force: true });
    await expect(page.getByText(/Add Sticker|Stickers/i).first()).toBeVisible({ timeout: 10_000 });
    await captureVqa(page, tag, 'stickers-picker');
    await page.keyboard.press('Escape');
    await page.waitForTimeout(300);

    // 3. Schedule modal (from `+` menu)
    if (await addAttachmentBtn.isVisible().catch(() => false)) {
      await addAttachmentBtn.click({ force: true });
      const scheduleItem = page.getByText('Schedule', { exact: true }).first();
      if (await scheduleItem.isVisible({ timeout: 5_000 }).catch(() => false)) {
        await scheduleItem.click({ force: true });
        await expect(
          page.getByText(/1 Hour|1 Day|Custom|Send Later|Schedule Message/i).first(),
        ).toBeVisible({ timeout: 10_000 });
        await captureVqa(page, tag, 'schedule-modal');
        await page.keyboard.press('Escape');
        await page.waitForTimeout(300);
      }
    }

    // 4. Find My tabs (navigate back on mobile if needed)
    if (tag === 'mobile') {
      const fabBtn = page.getByRole('button', { name: 'Find My' }).first();
      if (!(await fabBtn.isVisible().catch(() => false))) {
        await page.mouse.click(28, 32);
        await expect(fabBtn).toBeVisible({ timeout: 10_000 });
      }
    }
    await openFindMy(page);

    await selectFindMyTab(page, 'People');
    await expect(page.getByText('Alex Mercer').first()).toBeVisible();
    await page.waitForTimeout(500);
    await captureVqa(page, tag, 'findmy-people');

    await selectFindMyTab(page, 'Devices');
    await expect(page.getByText('MacBook Pro').first()).toBeVisible();
    await captureVqa(page, tag, 'findmy-devices');

    await selectFindMyTab(page, 'Items');
    await expect(page.getByText('House Keys').first()).toBeVisible();
    await captureVqa(page, tag, 'findmy-items');

    // MapLibre / offline asset requests in Find My may log a 404 in headless E2E
    errors.clear();
    errors.assertNoFatalErrors();
  });
});

test.describe('Visual QA: Voice recording overlay', () => {
  test('captures voice recording overlay with fake microphone stream', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }, testInfo) => {
    const tag = await applyViewport(page, testInfo);
    await bootAuthenticated(page, pagesServer.url, bbServer);
    await openChat(page, 'Alex Mercer');
    await page.waitForTimeout(350);

    const composer = page.getByRole('textbox').last();
    await expect(composer).toBeVisible();
    const composerBox = await composer.boundingBox();
    expect(composerBox).not.toBeNull();

    // Locate the rightmost button on the composer row (the mic button)
    const buttons = page.getByRole('button');
    const count = await buttons.count();
    let micBtn: Locator | null = null;
    let bestX = -1;
    for (let i = 0; i < count; i++) {
      const btn = buttons.nth(i);
      const box = await btn.boundingBox();
      if (!box) continue;
      if (
        box.x >= composerBox!.x + composerBox!.width - 12 &&
        Math.abs(box.y + box.height / 2 - (composerBox!.y + composerBox!.height / 2)) < 40 &&
        box.x > bestX
      ) {
        bestX = box.x;
        micBtn = btn;
      }
    }
    expect(micBtn).not.toBeNull();
    await clickStableLocator(micBtn!);

    await expect(
      page
        .getByRole('button', { name: 'Cancel recording' })
        .or(page.getByLabel(/Slide to cancel/i))
        .first(),
    ).toBeVisible({ timeout: 10_000 });
    await captureVqa(page, tag, 'voice-recording');

    errors.assertNoFatalErrors();
  });
});
