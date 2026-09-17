# App Attest — backend hardening plan (execute before public launch)

**Status:** planned, not built. Not needed for TestFlight or a soft launch — the
backend is already protected by per-device/per-IP rate limits + a global daily spend
cap (see `backend/`). App Attest matters when the app is **public** and the endpoint
could be hit by scripts. Build + test this on a real device before opening wide.

## What it buys us
Proof that a request comes from a **genuine, unmodified copy of our app on a real
Apple device** — so a leaked endpoint URL can't be hammered by a bot using our
server-side Groq key. Complements (doesn't replace) the rate limits.

## The flow
1. **Challenge:** app calls `GET /v1/attest/challenge` → server returns a random
   nonce (store it in KV with a short TTL, one-time use).
2. **Attest (first launch / new key):**
   - App: `DCAppAttestService.shared.generateKey()` → `keyId`.
   - App: `attestKey(keyId, clientDataHash: SHA256(nonce))` → attestation (CBOR).
   - App POSTs `{ keyId, attestationBase64, nonce }` to `POST /v1/attest`.
   - Server verifies (the hard part):
     - Parse the CBOR attestation object.
     - Verify the x5c **certificate chain to Apple's App Attest Root CA**.
     - Confirm the nonce hash is in the credCert extension (OID 1.2.840.113635.100.8.2).
     - Confirm the rpId hash == SHA256("<teamID>.design.irons.dictator").
     - Extract + store the public key keyed by `keyId` (KV/Durable Object).
   - Server issues a short-lived **JWT** (HMAC with a Worker secret), bound to `keyId`.
3. **Per request:** app sends `Authorization: Bearer <jwt>`. Server verifies the JWT.
   For stronger security, also require a per-request **assertion**
   (`generateAssertion`) and verify the signature + monotonic counter against the
   stored public key.

## Backend work (Cloudflare Worker)
- `GET /v1/attest/challenge`, `POST /v1/attest`, JWT verify middleware.
- Gate enforcement behind an env var **`ENFORCE_ATTEST`** (default `false`), so it
  ships dormant and is flipped on only after on-device verification passes.
- **Use a library** for the CBOR + X.509 verification rather than hand-rolling it
  (e.g. an App Attest verification package for Workers/Node). Hand-written ASN.1 is
  where this goes wrong.
- Store keyId→publicKey and per-key counters in a **Durable Object** (strongly
  consistent) once enforcing.

## iOS work
- `AppAttestClient` (DeviceCheck / `DCAppAttestService`):
  - `isSupported` guard (fails gracefully on Simulator / unsupported devices).
  - Generate + persist `keyId` (Keychain), attest once, cache the JWT, refresh on
    expiry, re-attest if the server rejects the key.
- In `BackendTranscription` / `BackendCleanup`: attach the JWT header **best-effort**
  — never block a dictation on attestation while `ENFORCE_ATTEST` is off.

## Rollout (safe order)
1. Ship backend + iOS code with `ENFORCE_ATTEST=false` (no behavior change).
2. On a real device, confirm attest → token → authorized request works end to end
   (watch `wrangler tail`).
3. Confirm graceful fallback on Simulator / older devices.
4. Flip `ENFORCE_ATTEST=true`. Keep the rate limits + global cap on regardless.

## Why not now
- Unverifiable without a device; blind crypto risks the working backend.
- Not required pre-public; current protection is adequate for TestFlight/soft launch.
