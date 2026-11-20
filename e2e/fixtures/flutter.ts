import * as fs from 'node:fs';
import * as path from 'node:path';
import type { Locator, Page } from '@playwright/test';

export const BB_WEB_CACHE_REV = 'bb-20261119-v7';

// 1x1 transparent PNG for stubbing external image/tile requests hermetically
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
  'base64',
);

export interface CapturedErrors {
  pageErrors: string[];
  consoleErrors: string[];
  assertNoFatalErrors: () => void;
  clear: () => void;
}

export interface BBServerLike {
  url: string;
  password: string;
  waitForSocket?: (timeoutMs?: number) => Promise<unknown>;
}

export interface BootAuthenticatedOptions {
  /** Navigate to a specific hash route, e.g. '/#/settings' */
  route?: string;
  /** Wait for initial sync / ConversationList ready (default: true) */
  waitForSync?: boolean;
  /** Wait for Socket.IO connection (default: true) */
  waitForSocket?: boolean;
  /** Extra localStorage keys (automatically prefixed with `flutter.` and JSON-stringified if needed) */
  extraStorage?: Record<string, unknown>;
}

/**
 * Attaches pageerror and console.error listeners to capture uncaught errors.
 */
export function attachErrorCollector(page: Page): CapturedErrors {
  const pageErrors: string[] = [];
  const consoleErrors: string[] = [];

  page.on('pageerror', (err) => {
    pageErrors.push(err?.stack || err?.message || String(err));
  });

  page.on('console', (msg) => {
    if (msg.type() !== 'error') return;
    const text = msg.text();
    // Ignore expected SRI digest mismatch when external CDNs (e.g. maplibre-gl) are stubbed hermetically
    if (text.includes("Failed to find a valid digest in the 'integrity' attribute")) {
      return;
    }
    consoleErrors.push(text);
  });

  return {
    pageErrors,
    consoleErrors,
    assertNoFatalErrors() {
      if (pageErrors.length > 0 || consoleErrors.length > 0) {
        const parts: string[] = [];
        if (pageErrors.length > 0) {
          parts.push(`Uncaught pageerrors (${pageErrors.length}):\n  - ${pageErrors.join('\n  - ')}`);
        }
        if (consoleErrors.length > 0) {
          parts.push(`Console errors (${consoleErrors.length}):\n  - ${consoleErrors.join('\n  - ')}`);
        }
        throw new Error(parts.join('\n'));
      }
    },
    clear() {
      pageErrors.length = 0;
      consoleErrors.length = 0;
    },
  };
}

function resolveCanvaskitDir(): string {
  const fromDirname = path.resolve(__dirname, '../../build/web/canvaskit');
  if (fs.existsSync(fromDirname)) return fromDirname;
  return path.resolve(process.cwd(), '../build/web/canvaskit');
}

/**
 * Stubs all non-localhost/non-127.0.0.1 HTTP(S) requests so tests are hermetic
 * and never leak network calls to Google Fonts, jsdelivr, map tiles, etc.
 * Serves local `build/web/canvaskit/*` for gstatic flutter-canvaskit requests.
 */
export async function installExternalCdnStub(page: Page): Promise<void> {
  const canvaskitDir = resolveCanvaskitDir();

  await page.route(/^https?:\/\/(?!(?:127\.0\.0\.1|localhost)(?::|\/|$))/i, async (route) => {
    const parsed = new URL(route.request().url());
    const url = parsed.href;
    const pathname = parsed.pathname.toLowerCase();

    // Serve local canvaskit / skwasm binaries for gstatic flutter-canvaskit URLs
    if (parsed.hostname === 'www.gstatic.com' && parsed.pathname.startsWith('/flutter-canvaskit/')) {
      const parts = parsed.pathname.split('/').filter(Boolean);
      // /flutter-canvaskit/<rev>/<rest...>
      const relPath = parts.slice(2).join('/');
      const localPath = path.resolve(canvaskitDir, relPath);
      if (localPath.startsWith(canvaskitDir + path.sep) && fs.existsSync(localPath)) {
        const ext = path.extname(localPath).toLowerCase();
        const contentType = ext === '.wasm'
          ? 'application/wasm'
          : ext === '.js' || ext === '.mjs'
            ? 'text/javascript; charset=utf-8'
            : 'application/octet-stream';
        return route.fulfill({
          status: 200,
          contentType,
          headers: {
            'Access-Control-Allow-Origin': '*',
            'Cross-Origin-Resource-Policy': 'cross-origin',
          },
          body: fs.readFileSync(localPath),
        });
      }
    }

    if (pathname.endsWith('.css') || url.includes('fonts.googleapis.com')) {
      return route.fulfill({ status: 200, contentType: 'text/css; charset=utf-8', body: '' });
    }
    if (pathname.endsWith('.mjs') || pathname.endsWith('.js')) {
      return route.fulfill({
        status: 200,
        contentType: 'application/javascript; charset=utf-8',
        body: 'export default {};',
      });
    }
    if (pathname.endsWith('.json')) {
      return route.fulfill({ status: 200, contentType: 'application/json; charset=utf-8', body: '{}' });
    }
    if (/\.(png|jpg|jpeg|webp|gif|ico)$/.test(pathname) || url.includes('tile')) {
      return route.fulfill({ status: 200, contentType: 'image/png', body: TINY_PNG });
    }
    if (/\.(woff2?|ttf|otf|eot)$/.test(pathname)) {
      return route.fulfill({ status: 200, contentType: 'font/woff2', body: Buffer.alloc(0) });
    }
    return route.fulfill({ status: 200, contentType: 'text/plain; charset=utf-8', body: '' });
  });
}

/**
 * Waits for Flutter Web (Wasm/CanvasKit) to mount and render its first frame.
 */
export async function waitForFlutterBoot(page: Page, timeout = 30_000): Promise<void> {
  await page.waitForFunction(
    () => {
      const splash = document.getElementById('splash');
      const host = document.querySelector('flutter-view, flt-glass-pane');
      return !splash && host !== null;
    },
    undefined,
    { timeout },
  );
}

/**
 * Clicks Flutter 3.50's `flt-semantics-placeholder` ("Enable accessibility")
 * and waits until `flt-semantics` nodes mount in the DOM.
 */
export async function enableSemantics(page: Page, timeout = 15_000): Promise<void> {
  const hasSemanticsNodes = () =>
    page.evaluate(() => {
      const countIn = (root: ParentNode | ShadowRoot | null): number => {
        if (!root) return 0;
        let count = root.querySelectorAll('flt-semantics').length;
        for (const el of root.querySelectorAll('flutter-view, flt-glass-pane')) {
          if (el.shadowRoot) count += countIn(el.shadowRoot);
        }
        return count;
      };
      return countIn(document) > 0;
    });

  if (await hasSemanticsNodes()) return;

  const placeholder = page.getByRole('button', { name: 'Enable accessibility' });
  await placeholder.waitFor({ state: 'attached', timeout });

  try {
    await placeholder.click({ force: true, timeout: 5_000 });
  } catch {
    // Fallback if element has zero bounding box in headless
    await page.evaluate(() => {
      const findPlaceholder = (root: ParentNode | ShadowRoot | null): HTMLElement | null => {
        if (!root) return null;
        const found = root.querySelector('flt-semantics-placeholder');
        if (found) return found as HTMLElement;
        for (const el of root.querySelectorAll('flutter-view, flt-glass-pane')) {
          if (el.shadowRoot) {
            const inner = findPlaceholder(el.shadowRoot);
            if (inner) return inner;
          }
        }
        return null;
      };
      const ph = findPlaceholder(document);
      if (ph) {
        ph.focus();
        ph.click();
        ph.dispatchEvent(new MouseEvent('click', { bubbles: true, composed: true }));
      }
    });
  }

  await page.waitForFunction(
    () => {
      const hasNodes = (root: ParentNode | ShadowRoot | null): boolean => {
        if (!root) return false;
        if (root.querySelectorAll('flt-semantics').length > 0) return true;
        for (const el of root.querySelectorAll('flutter-view, flt-glass-pane')) {
          if (el.shadowRoot && hasNodes(el.shadowRoot)) return true;
        }
        return false;
      };
      return hasNodes(document);
    },
    undefined,
    { timeout },
  );
}

/**
 * Builds the `localStorage` map needed by `shared_preferences` (`flutter.*`)
 * and `web/index.html` (`bb_web_cache_rev`) to boot directly into ConversationList.
 */
export function buildAuthLocalStorage(
  serverUrl: string,
  password: string,
  extra?: Record<string, unknown>,
): Record<string, string> {
  const normalizedUrl = serverUrl.replace(/\/+$/, '');
  const entries: Record<string, string> = {
    bb_web_cache_rev: BB_WEB_CACHE_REV,
    'flutter.migrationCompleted': JSON.stringify(true),
    'flutter.finishedSetup': JSON.stringify(true),
    'flutter.serverAddress': JSON.stringify(normalizedUrl),
    'flutter.guidAuthKey': JSON.stringify(password),
    'flutter.server-version': JSON.stringify('1.9.9'),
    'flutter.server-version-code': JSON.stringify(298),
    'flutter.macos-version': JSON.stringify(15),
    'flutter.macos-minor-version': JSON.stringify(0),
    'flutter.server-api-versions': JSON.stringify([1, 2]),
    'flutter.enablePrivateAPI': JSON.stringify(true),
    'flutter.serverPrivateAPI': JSON.stringify(true),
    'flutter.privateAPISend': JSON.stringify(true),
    'flutter.privateAPIAttachmentSend': JSON.stringify(true),
  };

  if (extra) {
    for (const [k, v] of Object.entries(extra)) {
      if (k === 'bb_web_cache_rev') {
        entries[k] = String(v);
      } else if (k.startsWith('flutter.')) {
        entries[k] = typeof v === 'string' ? v : JSON.stringify(v);
      } else {
        entries[`flutter.${k}`] = JSON.stringify(v);
      }
    }
  }

  return entries;
}

/**
 * Boots the app in a clean unauthenticated state and waits for SetupView ("Welcome to BlueBubbles").
 */
export async function bootFreshSetup(page: Page, pagesUrl: string): Promise<void> {
  await page.addInitScript((rev: string) => {
    try {
      if (!sessionStorage.getItem('__e2e_fresh_init')) {
        sessionStorage.setItem('__e2e_fresh_init', '1');
        localStorage.clear();
        localStorage.setItem('bb_web_cache_rev', rev);
      }
    } catch {
      // ignore storage errors on non-origin frames
    }
  }, BB_WEB_CACHE_REV);

  await page.goto(pagesUrl, { waitUntil: 'domcontentloaded' });
  await waitForFlutterBoot(page);
  await enableSemantics(page);
  await page.getByText('Welcome to BlueBubbles', { exact: false }).waitFor({ state: 'visible', timeout: 20_000 });
}

/**
 * Pre-seeds localStorage for an authenticated session, boots Wasm, enables semantics,
 * and waits for ConversationList + initial sync.
 */
export async function bootAuthenticated(
  page: Page,
  pagesUrl: string,
  bbServer: BBServerLike,
  opts: BootAuthenticatedOptions = {},
): Promise<void> {
  const storageEntries = buildAuthLocalStorage(bbServer.url, bbServer.password, opts.extraStorage);

  await page.addInitScript((entries: Record<string, string>) => {
    try {
      if (!sessionStorage.getItem('__e2e_auth_seeded')) {
        sessionStorage.setItem('__e2e_auth_seeded', '1');
        for (const [k, v] of Object.entries(entries)) {
          localStorage.setItem(k, v);
        }
      }
    } catch {
      // ignore
    }
  }, storageEntries);

  const targetUrl = opts.route
    ? `${pagesUrl.replace(/\/+$/, '')}${opts.route.startsWith('/') ? opts.route : `/${opts.route}`}`
    : pagesUrl;

  await page.goto(targetUrl, { waitUntil: 'domcontentloaded' });
  await waitForFlutterBoot(page);
  await enableSemantics(page);

  if (opts.waitForSocket !== false && bbServer.waitForSocket) {
    await bbServer.waitForSocket(15_000);
  }

  if (opts.waitForSync !== false) {
    // Dismiss Private API prompt if shown (e.g. if a test overrides enablePrivateAPI: false)
    const privateApiBtn = page.getByRole('button', { name: 'Enable Private API Features' });
    if (await privateApiBtn.isVisible().catch(() => false)) {
      await privateApiBtn.click();
    }

    // Wait until ConversationList search pill or a chat list renders and initial sync settles
    await page.getByText('Search BlueBubbles', { exact: false }).waitFor({ state: 'visible', timeout: 20_000 });
    const syncOverlay = page.getByLabel('Syncing…');
    if (await syncOverlay.isVisible().catch(() => false)) {
      await syncOverlay.waitFor({ state: 'hidden', timeout: 20_000 });
    }
  }
}

/**
 * Clicks a Flutter input (by Locator or accessible label/placeholder), clears it, and types text.
 */
export async function fillFlutterInput(
  page: Page,
  target: Locator | string,
  text: string,
): Promise<void> {
  const locator = typeof target === 'string'
    ? page.getByRole('textbox', { name: target }).or(page.getByLabel(target)).first()
    : target;

  await locator.click({ force: true });
  const mod = process.platform === 'darwin' ? 'Meta' : 'Control';
  await page.keyboard.press(`${mod}+a`);
  await page.keyboard.press('Backspace');
  if (text.length > 0) {
    await page.keyboard.insertText(text);
  }
}

/**
 * Dispatches a keyboard shortcut (normalizing ControlOrMeta).
 */
export async function pressShortcut(page: Page, shortcut: string): Promise<void> {
  await page.keyboard.press(shortcut);
}

/**
 * Opens a conversation from the ConversationList by matching its visible title/snippet.
 */
export async function openChat(page: Page, chatTitleOrPattern: string | RegExp): Promise<void> {
  const chatItem = page.getByText(chatTitleOrPattern).first();
  await chatItem.waitFor({ state: 'visible', timeout: 15_000 });
  await chatItem.click();
  // Wait for message composer textbox to appear
  await page.getByRole('textbox').last().waitFor({ state: 'visible', timeout: 15_000 });
}

/**
 * Types a message into the active ConversationView composer and submits with Enter.
 */
export async function sendMessage(page: Page, text: string): Promise<void> {
  const composer = page
    .getByRole('textbox', { name: /Text message|iMessage|New Message|Text Message/i })
    .or(page.getByRole('textbox').last())
    .first();

  await composer.click({ force: true });
  await page.keyboard.insertText(text);
  await page.keyboard.press('Enter');
}
