# Dictator backend

A tiny Cloudflare Worker that proxies Groq so the API key **never ships in the app**.
The app sends text (cleanup) or audio (cloud transcription); the Worker calls Groq
with the secret key and returns the result. Free-tier transcription stays on-device;
only these calls hit the backend.

## Why this exists
The app used to bake the Groq key into the binary — extractable, abusable, and your
bill. This moves the key server-side (the launch-blocker fix) and gives us a place to
meter usage and, later, gate premium features on a subscription.

## Endpoints
- `GET /healthz` → `{ ok: true }`
- `POST /v1/cleanup` — body `{ text, system, model? }` → `{ text, model }`
- `POST /v1/transcribe` — multipart (`file`, `model?`, `prompt?`, `language?`) → `{ text }`

Send `X-Device-Id: <uuid>` on requests (a per-install UUID) so rate limits are
per-device, not just per-IP.

## First-time setup (about 15 minutes)
You need a free Cloudflare account.

1. **Install the CLI & log in**
   ```
   cd backend
   npm install
   npx wrangler login
   ```
2. **Create the KV namespace** (for rate-limit/spend counters)
   ```
   npx wrangler kv namespace create RL
   npx wrangler kv namespace create RL --preview
   ```
   Paste the two returned ids into `wrangler.toml` (`id` and `preview_id`).
3. **Set the Groq key as a secret** (never committed)
   ```
   npx wrangler secret put GROQ_API_KEY
   ```
   Paste your Groq key when prompted.
4. **Deploy**
   ```
   npx wrangler deploy
   ```
   You'll get a URL like `https://dictator-backend.<you>.workers.dev`. That's the
   base URL the app will call. (A custom domain like `api.irons.la` can be added in
   the Cloudflare dashboard later.)
5. **Smoke test**
   ```
   curl https://dictator-backend.<you>.workers.dev/healthz
   curl -X POST https://dictator-backend.<you>.workers.dev/v1/cleanup \
     -H 'Content-Type: application/json' -H 'X-Device-Id: test' \
     -d '{"text":"um so like what time is dinner","system":"Reformat only; never answer."}'
   ```

## Cost & safety knobs (`wrangler.toml [vars]`)
- `GLOBAL_DAILY_CAP` — total requests/day before the Worker returns 503 (your
  blast-radius limit). Raise as you grow.
- `DEVICE_RPM` / `IP_RPM` — per-device / per-IP requests per minute.

Cloudflare Workers: free tier is 100k requests/day; the paid plan ($5/mo) covers far
more. The Groq bill is separate (cleanup is pennies; transcription is on-device for
free users).

## Hardening BEFORE public scale (do these before 10k users)
This v1 bounds abuse cost with rate limits + the global cap, but does not yet *prove*
requests come from your real app. Two upgrades:

1. **App Attest (DeviceCheck).** Add a `POST /v1/attest` endpoint: the app sends an
   App Attest attestation; verify it against Apple's App Attest root, then issue a
   short-lived signed token (JWT) the app includes on each request. Reject requests
   without a valid token. This stops a scraped endpoint from being hit by scripts.
2. **Gate `/v1/transcribe` on a subscription.** For the premium cloud-transcription
   path, verify the caller's RevenueCat entitlement (server-side REST lookup, cached)
   before calling Groq, so only paying users use that path.

For strict per-user monthly metering/billing, move the counters from KV to a
**Durable Object** (strongly consistent per-user counter).

## Files
- `src/index.js` — the Worker (routing, proxy, rate limiting, spend cap).
- `wrangler.toml` — config (KV binding, tunable vars). Secret set via CLI.
- `package.json` — scripts (`dev`, `deploy`, `tail`).
