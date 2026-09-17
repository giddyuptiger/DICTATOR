# Dictator — Business Model & Launch Plan

Working plan for taking Dictator from a TestFlight app to a paid product at scale
(target: ~10,000 users). Living document — edit freely. Dated 2026-09-17.

> **Pricing/legal caveat:** figures below come from cross-checked secondary sources
> (the research agents were blocked from some vendors' own pricing pages). Re-verify
> current prices on each provider's page before committing, and treat US external-
> payment law as unsettled (see §6).

---

## 1. The core idea

Two tiers, and the key realization from research is that the **free tier can be
zero-friction *and* cost us nothing** — no "paste an API key" step required.

| | **Free** | **Premium ("we handle it")** |
|---|---|---|
| Transcription | **On-device** (Parakeet, already bundled via FluidAudio) | **Cloud** (Groq Whisper v3 Turbo) via our backend |
| API key | None needed | We hold it, server-side |
| Cost to user | $0 | ~$8/mo (recommendation, see §5) |
| Cost to us | $0 | ~$0.30–0.40/user/mo transcription + tiny infra |
| Pitch | "Private. Works offline. Free forever." | "Best accuracy on hard audio, accents, and noise; live streaming; syncs across devices." |
| Optional 3rd path | **Bring-your-own-key** — advanced users paste their own Groq key for cloud quality at their own cost | — |

**Why this shape wins:** on-device transcription in 2026 is genuinely good
(Parakeet ≈ Whisper large-v3, ~2.5% word error rate), so the free tier is a real
product, not a crippled demo. "Your voice never leaves your phone" is a marketing
edge Wispr Flow can't match. The paid tier then sells *cloud quality on hard
audio + streaming + cross-device*, not merely "the thing that works."

---

## 2. Transcription (the AI layer)

**Free / default: on-device Parakeet via FluidAudio** (already a dependency).
Zero marginal cost, private, offline. `SpeechAnalyzer` (Apple, iOS 26+) is a good
zero-dependency alternative to A/B test later.

**Premium / cloud: Groq Whisper v3 Turbo — ~$0.04/hour of audio.** Cheapest cloud
option by a wide margin. ~$200/mo for 10,000 users each doing 30 min/mo. Batch,
not streaming (fine for tap-to-dictate; for live word-by-word later, Deepgram
Nova-3 is the best streaming option at ~$0.0077/min).

**Cleanup LLM (punctuation/formatting second pass): stay on Groq (Llama 4 Scout).**
A rounding error (~$3/mo per 1,000 users). One vendor, LPU speed. Claude Haiku 4.5
is higher quality if formatting becomes a differentiator (~8–13× the cost, still
cheap in absolute terms).

| Provider / model | Price | Streaming | Role |
|---|---|---|---|
| On-device Parakeet (FluidAudio) | $0 | chunked | **Free tier default** |
| Groq Whisper v3 Turbo | $0.04/hr | no | **Paid cloud default** |
| Groq Whisper large v3 | $0.111/hr | no | Higher-accuracy cloud option |
| Deepgram Nova-3 (streaming) | ~$0.0077/min | yes | Future "live" pro mode |
| OpenAI gpt-4o-transcribe | $0.006/min | yes | Accuracy leader, pricier |

Commercial terms for Groq/OpenAI/Deepgram all permit building a paid product on
top; raw-API *resale* needs care but our proxy model is fine.

---

## 3. Backend (only needed for the paid tier)

Free/BYOK users never touch our backend — the app calls Groq directly with the
on-device model or the user's own key, so **only paying users can cost us money.**
That alone caps most of the risk.

**Recommended stack:**

| Layer | Choice | Why |
|---|---|---|
| Proxy hosting | **Cloudflare Workers** ($5/mo floor) | Effectively no cold start (hard requirement for real-time); CPU-only billing (we pay ~ms of CPU while *waiting* on Groq for free); no ingress bandwidth charge (we upload audio) |
| Usage/rate state | Cloudflare **Durable Objects** / KV | Per-user monthly meter + token-bucket rate limit |
| App authenticity | **App Attest (DeviceCheck)** → short-lived JWT | Proves a request is our real app on a real device; contains leaked-token abuse |
| Durable identity (paid) | **Sign in with Apple** | Subscription survives reinstalls/second device (the #1 support headache) |
| Entitlement truth | **RevenueCat** REST lookup (cached) | Never trust the client that it's premium |
| Payments | **StoreKit 2 auto-renewable IAP** + RevenueCat | Apple requires IAP for digital subs |
| Secrets | Cloudflare **Workers Secrets** | Groq key server-side only, never in the binary |

**Fallback:** if we ever need long recordings or persistent streaming, **Fly.io
with one always-warm machine** (avoid scale-to-zero cold boot).

**Data flow (paid):** App Attest → Worker issues JWT → app sends audio + JWT →
Worker verifies JWT, checks entitlement (RevenueCat, cached), checks/increments
usage meter, forwards audio to Groq (key from secret), returns transcript.

---

## 4. Payments & Apple's rules

- Digital subscription **must** use Apple IAP (Guideline 3.1.1). Set up an
  auto-renewable subscription in App Store Connect.
- **Enroll in the Small Business Program → flat 15% cut** (vs 30%), and for subs
  you get 15% from day one. Free money for a solo founder under $1M/yr.
- **Use RevenueCat:** free up to $2,500/mo tracked revenue, then 1% of tracked
  revenue. It handles JWS/receipt validation, renewals, grace periods, App Store
  Server Notifications, cross-device entitlement, and the server-side entitlement
  API our proxy needs. Weeks of work saved; roll our own only far past 10k users.
- **US external payment links:** currently 0% Apple commission (post-Epic), but
  legally in flux — Apple has *proposed* 15%/5%, Supreme Court likely rules ~2027.
  **Launch with IAP + SBP.** Don't architect around the temporary 0% window; add a
  Stripe web checkout only later, with volume to justify two payment paths.

---

## 5. Pricing recommendation

- **Free:** on-device, unlimited, forever. This is the growth engine.
- **Premium: ~$8/month or ~$60/year** (undercut Wispr's $15/mo; annual improves
  retention and cash flow). Consider a 7-day free trial of premium.
- **BYOK:** free (they pay Groq directly). Frame as an advanced option, not a way
  to unlock premium features.

**Unit economics at premium $8/mo, 15% Apple cut, ~1.4% RevenueCat on net:**
- Net per subscriber ≈ **$6.70/mo**.
- Transcription COGS for a heavy user ≈ **$0.30–0.40/mo** (Groq Turbo; meter
  *billed* seconds — Groq has a 10-second per-request minimum).
- **Gross margin per paid user ≈ 94%.** Very healthy.

**Illustrative at 10,000 users, ~15% paid (1,500 subs):**
- Revenue ≈ 1,500 × $8 = **$12,000/mo** gross; ~$10,000/mo net after Apple.
- Infra ≈ **$160–190/mo** (Workers + Durable Objects + RevenueCat's 1%).
- Groq transcription ≈ **$450–600/mo** for heavy paid users.
- **≈ $9,200/mo contribution.** The model works; the constraint is *getting the
  users*, not the economics.

---

## 6. Cost summary

| | 1,000 users (~150 paid) | 10,000 users (~1,500 paid) |
|---|---|---|
| Cloudflare Workers + DO/KV | ~$5–10 | ~$10–40 |
| RevenueCat | $0 (under free threshold) | ~$150 (1% of tracked rev) |
| **Infra subtotal** | **~$5–10/mo** | **~$160–190/mo** |
| Groq transcription (paid users) | ~$45–90/mo | ~$450–600/mo |
| On-device (free users) | $0 | $0 |

---

## 7. Launch roadmap

**Phase 0 — polish (mostly done).** Keyboard, wake screen, music behavior,
paragraphs, stability. ✅ Ongoing on TestFlight.

**Phase 1 — free tier that stands alone (no backend).**
1. Wire on-device Parakeet (FluidAudio) as the default transcription path; keep
   cloud behind a flag. Removes the baked-in key problem for free users entirely.
2. Remove the embedded Groq key from shipping builds; add a clean BYOK onboarding
   ("get your free Groq key in 90 seconds," illustrated) as the *optional* cloud path.
3. Ship a **privacy policy + terms** (required for review — audio leaves the device
   on the cloud/BYOK path). Host on a simple site.
4. App Store listing: description, subtitle, keywords, screenshots, category, age
   rating, App Privacy answers; verify the Privacy Manifests match reality.
5. Reviewer notes: explain the keyboard→app mic hop, Full Access justification, and
   give a sandbox path. **This alone is a shippable App Store launch (free app).**

**Phase 2 — premium backend + subscription.**
1. Cloudflare Worker proxy (App Attest → JWT → entitlement → meter → Groq).
2. RevenueCat + StoreKit 2 auto-renewable subscription; Small Business Program.
3. Sign in with Apple for durable entitlement; Restore Purchases.
4. Usage cap + global spend circuit-breaker/kill-switch.
5. Submit premium update.

**Phase 3 — growth.** ASO, referral, the "private/offline" angle, maybe a live-
streaming "pro" mode (Deepgram) later.

---

## 8. Risks & App Review gotchas

1. **Keyboards can't use the mic.** Recording must happen in the container app (we
   already do this). A reviewer who can't get audio *from the keyboard* will reject
   — make the flow obvious and document it in review notes.
2. **Full Access scrutiny.** Needs a real privacy policy, accurate Privacy Nutrition
   Label, Privacy Manifest, and NSMicrophoneUsageDescription. Be transparent that a
   Full-Access keyboard *can* read text fields.
3. **IAP mandatory** for premium; mind anti-steering — ship IAP-only first.
4. **Restore purchases / refunds / upgrade paths** are tested by reviewers.
5. **Avoid the Accessibility API** for text insertion (a dictation app was reportedly
   rejected for it) — stay in the keyboard-extension model.
6. **Offline handling** on the cloud path — clear message, not a silent failure.

---

## 9. Open decisions (need Jeremy)

- [ ] Confirm the on-device-free / cloud-paid direction (vs. BYOK-only free).
- [ ] Premium price: $8/mo + $60/yr? Free trial length?
- [ ] Is a launch as a **free app first** (Phase 1) acceptable, with premium as a
      fast follow (Phase 2)? Recommended — gets you to the store fastest.
- [ ] Who writes the privacy policy / terms (I can draft them)?

## 10. Things to verify before committing money
- Current Groq / Deepgram / OpenAI prices on their own pages.
- Cloudflare Workers request-body size limit vs. our max clip length.
- Live status of US external-payment commission at launch.
- On-device Parakeet quality on *your* real audio (accents, noise) vs. cloud.
