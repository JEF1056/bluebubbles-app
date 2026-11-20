import {
  test,
  expect,
  bootAuthenticated,
  openChat,
} from '../fixtures/test';
import { makeFindMyDevice, makeFindMyFriend } from '../server/fixtures-data';

async function openFindMy(page: import('@playwright/test').Page): Promise<void> {
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

async function selectFindMyTab(
  page: import('@playwright/test').Page,
  tabName: 'People' | 'Devices' | 'Items',
): Promise<void> {
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

async function clickStableLocator(locator: import('@playwright/test').Locator): Promise<void> {
  await expect(locator).toBeVisible({ timeout: 15_000 });
  let prev: { x: number; y: number; width: number; height: number } | null = null;
  await expect(async () => {
    const box = await locator.boundingBox();
    expect(box).not.toBeNull();
    expect(box!.width).toBeGreaterThan(10);
    expect(box!.height).toBeGreaterThan(10);
    if (
      !prev ||
      Math.abs(box!.x - prev.x) > 1 ||
      Math.abs(box!.y - prev.y) > 1
    ) {
      prev = box;
      throw new Error('Wait for TabBarView slide animation to settle');
    }
  }).toPass({ timeout: 5_000, intervals: [100] });
  await locator.click({ force: true });
}

test.describe('Find My & FaceTime', () => {
  test('loads Find My People/Devices/Items tabs, refreshes locations, and applies live socket updates', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    await openFindMy(page);

    // Opening Find My activates FindMyController.activatePage(), triggering initial refresh + loading seeded data
    await expect
      .poll(() => bbServer.getRequests('POST', '/api/v1/icloud/findmy/devices/refresh').length, { timeout: 15_000 })
      .toBeGreaterThanOrEqual(1);
    await expect
      .poll(() => bbServer.getRequests('POST', '/api/v1/icloud/findmy/friends/refresh').length, { timeout: 15_000 })
      .toBeGreaterThanOrEqual(1);

    // People tab (default): seeded friends
    await selectFindMyTab(page, 'People');
    await expect(page.getByText('Alex Mercer').first()).toBeVisible();
    await expect(page.getByText('Sam Rivera').first()).toBeVisible();

    // Devices tab: seeded non-accessory devices
    await selectFindMyTab(page, 'Devices');
    await expect(page.getByText('MacBook Pro').first()).toBeVisible();
    await expect(page.getByText('iPhone 16 Pro').first()).toBeVisible();

    // Items tab: seeded accessory trackers
    await selectFindMyTab(page, 'Items');
    await expect(page.getByText('House Keys').first()).toBeVisible();
    await expect(page.getByText('Travel Backpack').first()).toBeVisible();

    // Emit live socket device update, then trigger explicit refresh -> POST /api/v1/icloud/findmy/{devices,friends}/refresh
    const liveDevice = makeFindMyDevice({
      id: 'dev-ipad-pro-live',
      name: 'iPad Pro M4',
      deviceModel: 'iPad16,3',
      modelDisplayName: 'iPad Pro',
      deviceDisplayName: 'iPad Pro',
      isConsideredAccessory: false,
    });
    bbServer.emitFindMyDevice(liveDevice);

    const refreshBtn = page.getByRole('button', { name: 'Refresh Locations' }).first();
    await expect(refreshBtn).toBeEnabled({ timeout: 10_000 });
    bbServer.clearRequests();

    const devicesRefreshPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/icloud/findmy/devices/refresh',
    );
    const friendsRefreshPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/icloud/findmy/friends/refresh',
    );
    await refreshBtn.click({ force: true });

    await Promise.all([devicesRefreshPromise, friendsRefreshPromise]);

    await selectFindMyTab(page, 'Devices');
    await expect(page.getByText('iPad Pro M4').first()).toBeVisible({ timeout: 15_000 });

    // Live new-findmy-location socket update for a friend
    bbServer.emitFindMyFriend(
      makeFindMyFriend({
        title: 'Taylor Brooks',
        subtitle: 'Cupertino, CA',
        handle: 'taylor.brooks@icloud.com',
        coordinates: [37.3349, -122.009],
        long_address: 'One Apple Park Way, Cupertino, CA',
        short_address: 'Cupertino, CA',
        status: 'live',
        last_updated: Date.now(),
      }),
    );

    await selectFindMyTab(page, 'People');
    await expect(page.getByText('Taylor Brooks').first()).toBeVisible({ timeout: 15_000 });

    errors.assertNoFatalErrors();
  });

  test('supports Play Sound success + HTTP 400 error handling and Web Find Nearby fallback', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    await openFindMy(page);
    await selectFindMyTab(page, 'Items');

    const keysRow = page.getByText('House Keys').first();
    await clickStableLocator(keysRow);

    // 1. Play Sound success -> Stop Sound
    const playSoundBtn = page.getByRole('button', { name: 'Play Sound' }).first();
    await expect(playSoundBtn).toBeVisible();

    const ringStartPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/icloud/findmy/devices/ring',
    );
    await playSoundBtn.click({ force: true });
    const ringStartReq = await ringStartPromise;
    expect(ringStartReq.body).toMatchObject({
      deviceId: 'item-airtag-keys',
      action: 'start',
    });

    const stopSoundBtn = page.getByRole('button', { name: 'Stop Sound' }).first();
    await expect(stopSoundBtn).toBeVisible({ timeout: 10_000 });

    // Stop Sound -> Play Sound
    const ringStopPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/icloud/findmy/devices/ring',
    );
    await stopSoundBtn.click({ force: true });
    const ringStopReq = await ringStopPromise;
    expect(ringStopReq.body).toMatchObject({
      deviceId: 'item-airtag-keys',
      action: 'stop',
    });
    await expect(playSoundBtn).toBeVisible({ timeout: 10_000 });

    // 2. Play Sound HTTP 400 error handling
    bbServer.failNext('POST', '/api/v1/icloud/findmy/devices/ring', 400, {
      error: 'Item is out of range',
    });
    const ringFailPromise = bbServer.waitForRequest(
      'POST',
      '/api/v1/icloud/findmy/devices/ring',
    );
    await playSoundBtn.click({ force: true });
    await ringFailPromise;

    await expect(stopSoundBtn).toHaveCount(0);
    await expect(playSoundBtn).toBeVisible();
    errors.clear(); // Clear intentional HTTP 400 console error (and any maplibre asset warning)

    // 3. Open Detail Sheet and trigger Web Find Nearby fallback
    const detailsBtn = page.getByRole('button', { name: 'Details' }).first();
    const findNearbyTile = page.getByRole('button', { name: 'Find Nearby' }).first();
    await expect(async () => {
      await clickStableLocator(detailsBtn);
      await expect(findNearbyTile).toBeVisible({ timeout: 2_000 });
    }).toPass({ timeout: 10_000, intervals: [200] });

    await clickStableLocator(findNearbyTile);

    // On Web, Find Nearby falls back cleanly without opening a BLE radar sheet or throwing errors
    await expect(findNearbyTile).toBeVisible();

    errors.assertNoFatalErrors();
  });

  test('displays incoming FaceTime banner via socket events and initiates outgoing call via API', async ({
    page,
    pagesServer,
    bbServer,
    errors,
  }) => {
    await bootAuthenticated(page, pagesServer.url, bbServer);

    const searchGroup = page.getByRole('group', { name: /Search/i }).first();
    await expect(searchGroup).toBeVisible();
    const boxBefore = await searchGroup.boundingBox();
    expect(boxBefore).not.toBeNull();

    // Legacy incoming-facetime socket event is handled without errors
    bbServer.emitIncomingFaceTime({ caller: '+15550100001' });

    // Full session ft-call-status-changed (status_id: 4 incoming) mounts the top Continuity banner,
    // shifting the main shell down by the banner height (~56px)
    bbServer.emitIncomingFaceTime({
      uuid: 'ft-in-e2e-1',
      address: '+15550100001',
      is_video: true,
      is_audio: false,
    });

    await expect
      .poll(async () => (await searchGroup.boundingBox())?.y ?? 0, { timeout: 15_000 })
      .toBeGreaterThan((boxBefore?.y ?? 0) + 30);

    // Open Alex Mercer chat and verify outgoing FaceTime call initiation API
    await openChat(page, 'Alex Mercer');

    const videoBtn = page.getByRole('button', { name: 'Video' }).first();
    await expect(videoBtn).toBeVisible();

    const callReqPromise = bbServer.waitForRequest(
      'POST',
      /^\/api\/v[12]\/facetime\/(session|call)/,
    );
    await videoBtn.click({ force: true });
    await callReqPromise;

    await expect(
      page.getByText(/Ringing|Calling|FaceTime/i).first(),
    ).toBeVisible({ timeout: 10_000 });

    const closeOrHangUpBtn = page.getByRole('button', { name: /Close|Hang Up|Cancel call/i }).first();
    if (await closeOrHangUpBtn.isVisible().catch(() => false)) {
      await closeOrHangUpBtn.click({ force: true, timeout: 2_000 }).catch(() => {});
    }

    errors.assertNoFatalErrors();
  });
});
