# BlueBubbles Web Deployment (Cloudflare Pages)

Concise runbook for building and publishing BlueBubbles Web (Wasm/Skwasm) to Cloudflare Pages via [`.github/workflows/web-deploy.yml`](../.github/workflows/web-deploy.yml).

## 1. GitHub Actions Workflow & Secrets

- **Triggers:**
  - `push` to `master` or manual `workflow_dispatch`: builds `build/web` and deploys to Cloudflare Pages project **`bluebubbles-web`** via `cloudflare/wrangler-action@v3`.
  - `pull_request`: runs the same Wasm build and uploads `build/web` as the `bluebubbles-web-preview` workflow artifact (no deploy).
- **Repository Secrets (`JEF1056/bluebubbles-app` → Settings → Secrets and variables → Actions):**
  - `CLOUDFLARE_API_TOKEN` *(required for deploy)*: API token with **Cloudflare Pages: Edit** permission.
  - `CLOUDFLARE_ACCOUNT_ID` *(required for deploy)*: Cloudflare account ID hosting `bluebubbles-web`.
  - `GOOGLE_WEB_CLIENT_ID` *(optional)*: Passed via `--dart-define=GOOGLE_WEB_CLIENT_ID=...` if Google OAuth is enabled for `https://chat.jessfan.com`.
  - *(Note: `KLIPY_API_KEY` is intentionally left blank in `.env` during web CI because `build/web/assets/.env` is served publicly.)*

## 2. Cloudflare Pages & Custom Domain (`chat.jessfan.com`)

1. **Check existing DNS / Tunnel routing:** Verify whether `chat.jessfan.com` is currently bound in a Cloudflare Tunnel or DNS record (e.g., `JEF1056/custom-llama` → `llama-server:8080`). Either migrate the existing service to another subdomain (such as `ai.jessfan.com` or `llm.jessfan.com`) or remove the old record before attaching it to Pages.
2. **Create Pages project:** In Cloudflare Dashboard → **Workers & Pages** → Create project **`bluebubbles-web`** (Direct Upload / Wrangler deployment; no Cloudflare git build needed).
3. **Attach custom domain:** In the `bluebubbles-web` project → **Custom domains** → Add **`chat.jessfan.com`**.

## 3. Headers & Routing (`web/_headers`, `web/_redirects`)

Flutter copies `web/_headers` and `web/_redirects` directly into `build/web/`:

- `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: credentialless` enable `window.crossOriginIsolated` (multi-threaded Skwasm via `SharedArrayBuffer`) while still allowing cross-origin media/tiles without `CORP` headers.
- `Referrer-Policy: no-referrer` prevents `?password=...` server URLs from leaking in `Referer` headers.
- `no-cache` on `/index.html`, `/flutter_bootstrap.js`, `/flutter_service_worker.js`, and `/version.json`; `immutable` 1-year caching on `/assets/*` and `/canvaskit/*`.
- `/* /index.html 200` in `web/_redirects` provides SPA fallback routing.

## 4. Optional Cloudflare Access (Zero Trust)

To gate `chat.jessfan.com` behind Cloudflare Zero Trust authentication, attach a **Cloudflare Access** self-hosted application policy to `chat.jessfan.com` in the Zero Trust dashboard. It sits cleanly in front of Cloudflare Pages without changes to the app build.

## 5. Local Build & Smoke Test

```bash
fvm flutter build web --wasm --release --base-href /
npx wrangler pages dev build/web
```
