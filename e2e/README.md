# BlueBubbles Web E2E Suite

Hermetic Playwright end-to-end tests for the Flutter Web Wasm build (`build/web`), served with Cloudflare Pages `_headers` / `_redirects` parity and backed by an in-process mock BlueBubbles HTTP + Socket.IO server.

## Prerequisites

Build the Web Wasm bundle once from the repo root (or via `npm run build:web`):

```bash
flutter build web --wasm --release --base-href /
```

Install E2E dependencies (first time):

```bash
cd e2e && npm install
```

## Run Commands

```bash
cd e2e

# Desktop suite (1440x900, default)
npm test

# Smoke spec only
npm run test:smoke

# Specific spec(s)
npx playwright test tests/01-pwa-security-boot.spec.ts tests/02-setup-sync-reconnect.spec.ts

# Responsive viewports
npm run test:tablet   # 900x1024
npm run test:mobile   # 390x844
npm run test:all      # desktop + tablet + mobile

# Typecheck
npm run typecheck
```

## Projects

Defined in [playwright.config.ts](playwright.config.ts):
- `desktop`: `1440x900` Chrome headless
- `tablet`: `900x1024` Chrome headless
- `mobile`: `390x844` Chrome headless

## Architecture

- `server/pages-server.ts`: Static HTTP server for `build/web` that parses `web/_headers` and `web/_redirects` (COOP/COEP `crossOriginIsolated`, `Cache-Control` tiers, `/_a/:rev/*` rewrites, SPA fallback).
- `server/mock-bb-server.ts`: Ephemeral HTTP + Socket.IO mock BlueBubbles server with request recording, fault injection (`failNext`, `setRouteOverride`), and live socket event emitters.
- `server/fixtures-data.ts`: Deterministic seed builders (`createDefaultSeed`, `makeChat`, `makeMessage`, `makeAttachment`, etc.).
- `fixtures/test.ts` & `fixtures/flutter.ts`: Worker-scoped `pagesServer`, test-scoped `bbServer` + `errors` collector, external CDN stubbing (serving local `canvaskit/`), Flutter Wasm boot & semantics helpers (`bootFreshSetup`, `bootAuthenticated`, `openChat`, `sendMessage`).
