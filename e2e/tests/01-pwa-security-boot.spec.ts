import {
  test,
  expect,
  BB_WEB_CACHE_REV,
  waitForFlutterBoot,
} from '../fixtures/test';

test.describe('PWA, Security Headers & Wasm Boot', () => {
  test('serves COOP/COEP, security headers, crossOriginIsolated === true, and removes #splash on first frame', async ({
    page,
    pagesServer,
    errors,
  }) => {
    const response = await page.goto(pagesServer.url, { waitUntil: 'domcontentloaded' });
    expect(response).not.toBeNull();
    expect(response!.status()).toBe(200);

    const headers = response!.headers();
    expect(headers['cross-origin-opener-policy']).toBe('same-origin');
    expect(headers['cross-origin-embedder-policy']).toBe('credentialless');
    expect(headers['x-content-type-options']).toBe('nosniff');
    expect(headers['referrer-policy']).toBe('strict-origin-when-cross-origin');
    expect(headers['cache-control']).toBe('no-cache');
    if (headers['permissions-policy'] !== undefined) {
      expect(headers['permissions-policy'].length).toBeGreaterThan(0);
    }

    await waitForFlutterBoot(page);

    const bootState = await page.evaluate(() => ({
      crossOriginIsolated: window.crossOriginIsolated,
      splashPresent: document.getElementById('splash') !== null,
      hostPresent: document.querySelector('flutter-view, flt-glass-pane') !== null,
      cacheRev: localStorage.getItem('bb_web_cache_rev'),
    }));

    expect(bootState.crossOriginIsolated).toBe(true);
    expect(bootState.splashPresent).toBe(false);
    expect(bootState.hostPresent).toBe(true);
    expect(bootState.cacheRev).toBe(BB_WEB_CACHE_REV);

    errors.assertNoFatalErrors();
  });

  test('enforces Cache-Control tiers, SPA fallback, and /_a/:rev/* rewrite', async ({
    page,
    pagesServer,
  }) => {
    // Shell files: no-cache
    for (const shellPath of ['/', '/index.html', '/flutter_bootstrap.js', '/version.json']) {
      const res = await page.request.get(`${pagesServer.url}${shellPath}`);
      expect(res.status(), `GET ${shellPath}`).toBe(200);
      expect(res.headers()['cache-control'], `Cache-Control for ${shellPath}`).toBe('no-cache');
    }

    // Versioned /_a/:rev/* rewrite: 200 + immutable
    const versionRes = await page.request.get(`${pagesServer.url}/version.json`);
    const versionBody = await versionRes.text();

    const revRes = await page.request.get(`${pagesServer.url}/_a/${BB_WEB_CACHE_REV}/version.json`);
    expect(revRes.status()).toBe(200);
    expect(revRes.headers()['cache-control']).toBe('public, max-age=31536000, immutable');
    expect(await revRes.text()).toBe(versionBody);

    // CanvasKit assets: immutable
    const ckRes = await page.request.get(`${pagesServer.url}/canvaskit/canvaskit.js`);
    expect(ckRes.status()).toBe(200);
    expect(ckRes.headers()['cache-control']).toBe('public, max-age=31536000, immutable');

    // SPA fallback: unknown route -> 200 index.html
    const spaRes = await page.request.get(`${pagesServer.url}/unknown/route/deep/link`);
    expect(spaRes.status()).toBe(200);
    expect(spaRes.headers()['content-type']).toContain('text/html');
    const spaHtml = await spaRes.text();
    expect(spaHtml).toContain('<title>BlueBubbles</title>');
    expect(spaHtml).toContain('flutter_bootstrap.js');
  });

  test('purges stale CacheStorage entries and updates bb_web_cache_rev on rev mismatch', async ({
    page,
    pagesServer,
    errors,
  }) => {
    await page.addInitScript(() => {
      try {
        if (!sessionStorage.getItem('__e2e_stale_seeded')) {
          sessionStorage.setItem('__e2e_stale_seeded', '1');
          localStorage.setItem('bb_web_cache_rev', 'stale-rev-0');
          if ('caches' in window) {
            void caches.open('bb-stale-cache-v0').then((c) => c.put('/stale-key', new Response('old')));
          }
        }
      } catch {
        // ignore
      }
    });

    await page.goto(pagesServer.url, { waitUntil: 'domcontentloaded' });
    await waitForFlutterBoot(page);

    const state = await page.evaluate(async () => {
      const cacheKeys = 'caches' in window ? await caches.keys() : [];
      return {
        rev: localStorage.getItem('bb_web_cache_rev'),
        cacheKeys,
      };
    });

    expect(state.rev).toBe(BB_WEB_CACHE_REV);
    expect(state.cacheKeys).not.toContain('bb-stale-cache-v0');
    errors.assertNoFatalErrors();
  });

  test('serves valid manifest.json with standalone display, icons, and share_target', async ({
    page,
    pagesServer,
  }) => {
    const res = await page.request.get(`${pagesServer.url}/manifest.json`);
    expect(res.status()).toBe(200);
    expect(res.headers()['cache-control']).toContain('must-revalidate');

    const manifest = await res.json();
    expect(manifest.name).toBe('BlueBubbles');
    expect(manifest.display).toBe('standalone');
    expect(manifest.start_url).toBe('/');
    expect(Array.isArray(manifest.icons)).toBe(true);
    expect(manifest.icons.length).toBeGreaterThanOrEqual(4);
    expect(manifest.icons.some((i: { sizes?: string }) => i.sizes === '192x192')).toBe(true);
    expect(manifest.icons.some((i: { sizes?: string }) => i.sizes === '512x512')).toBe(true);
    expect(manifest.icons.some((i: { purpose?: string }) => i.purpose === 'maskable')).toBe(true);
    expect(manifest.share_target).toMatchObject({
      action: '/',
      method: 'GET',
      params: {
        title: 'title',
        text: 'text',
        url: 'url',
      },
    });
  });
});
