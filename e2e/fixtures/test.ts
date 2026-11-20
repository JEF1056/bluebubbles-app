import * as fs from 'node:fs';
import * as path from 'node:path';
import { test as base, expect } from '@playwright/test';
import { startPagesServer, type PagesServer } from '../server/pages-server';
import { startMockBBServer, type MockBBServer } from '../server/mock-bb-server';
import {
  attachErrorCollector,
  installExternalCdnStub,
  type CapturedErrors,
} from './flutter';

function resolveRepoRoot(): string {
  const fromDirname = path.resolve(__dirname, '../..');
  if (fs.existsSync(path.join(fromDirname, 'build/web/index.html'))) {
    return fromDirname;
  }
  const fromCwd = path.resolve(process.cwd(), '..');
  if (fs.existsSync(path.join(fromCwd, 'build/web/index.html'))) {
    return fromCwd;
  }
  return fromDirname;
}

export interface WorkerFixtures {
  pagesServer: PagesServer;
}

export interface TestFixtures {
  bbServer: MockBBServer;
  errors: CapturedErrors;
}

export const test = base.extend<TestFixtures, WorkerFixtures>({
  pagesServer: [
    async ({}, use) => {
      const repoRoot = resolveRepoRoot();
      const server = await startPagesServer({
        buildDir: path.join(repoRoot, 'build/web'),
        webDir: path.join(repoRoot, 'web'),
      });
      await use(server);
      await server.close();
    },
    { scope: 'worker' },
  ],

  bbServer: async ({}, use) => {
    const server = await startMockBBServer();
    await use(server);
    await server.close();
  },

  errors: async ({ page }, use) => {
    const collector = attachErrorCollector(page);
    await use(collector);
  },

  page: async ({ page }, use) => {
    await installExternalCdnStub(page);
    await use(page);
  },
});

export { expect };
export * from './flutter';
