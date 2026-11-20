import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  // Recovers from ~1% headless Chrome macOS Skwasm first-frame OffscreenCanvas deadlock.
  retries: process.env.CI ? 2 : 1,
  // Cap local concurrency at 4 to avoid Skwasm/WebGL2 context stalls on high-core hosts.
  workers: process.env.CI ? 2 : 4,
  timeout: 60_000,
  expect: {
    timeout: 15_000,
  },
  reporter: [
    ['list'],
    ['html', { open: 'never' }],
  ],
  use: {
    channel: 'chrome',
    headless: true,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: 'desktop',
      use: {
        viewport: { width: 1440, height: 900 },
      },
    },
    {
      name: 'tablet',
      use: {
        viewport: { width: 900, height: 1024 },
      },
    },
    {
      name: 'mobile',
      use: {
        viewport: { width: 390, height: 844 },
      },
    },
  ],
});
