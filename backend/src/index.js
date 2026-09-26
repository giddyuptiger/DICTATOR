// Dictator backend — a thin edge proxy that holds the Groq API key SERVER-SIDE so
// it never ships inside the app. The app sends text (for cleanup) or audio (for
// cloud transcription); this Worker calls Groq with the secret key and returns the
// result. Transcription for the free tier stays on-device; only these calls hit the
// backend.
//
// Endpoints:
//   GET  /healthz                                    -> { ok: true }
//   POST /v1/cleanup     { text, system, model? }    -> { text }
//   POST /v1/transcribe  multipart(file, model?, prompt?, language?) -> { text }
//   POST /v1/dictate     multipart(file, system, model?, prompt?, language?, cleanup_model?)
//                                                        -> { raw, text, cleaned }
//                        (transcribe + cleanup in one round trip — the fast path)
//
// SECURITY POSTURE (v1):
//   - The Groq key lives ONLY in a Worker secret (never in the app binary). This is
//     the whole point: the launch-blocker (extractable embedded key) is gone.
//   - Abuse cost is bounded by per-device + per-IP rate limits and a GLOBAL daily
//     spend circuit-breaker (all in KV).
//   - BEFORE public scale, add the two hardening steps in README.md:
//       (1) App Attest — prove requests come from a genuine app instance.
//       (2) Gate /v1/transcribe on a verified RevenueCat subscription.
//     Until then, the rate limits + global cap are what bound your exposure.

const GROQ_BASE = "https://api.groq.com/openai/v1";

// Cleanup models, tried in order. Groq shut down llama-3.1-8b-instant and
// llama-3.3-70b-versatile on 2026-08-16 (404 model_not_found), Llama 4 Scout on
// 2026-07-17, and gemma2-9b-it before that. Until this list was updated every
// cleanup paid for a 404 round trip and then ran gpt-oss-20b at its default
// (medium) reasoning effort, which is what made dictations slow. Both gpt-oss
// models are reasoning models: they think before they answer, so they are asked
// for "low" effort (see chatBody); cleanup is a rewrite, not a puzzle.
const CLEANUP_MODELS = [
  "openai/gpt-oss-20b",
  "openai/gpt-oss-120b",
];

// Upper bound on the whole cleanup stage. Past it the user gets Whisper's own
// (already punctuated) transcript instead of waiting; the app logs it as
// "cleanup: NOT applied".
const CLEANUP_BUDGET_MS = 5000;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({ ok: true });
      }

      // Waitlist signup from the marketing site (browser -> CORS). Handled BEFORE
      // the Groq spend cap and device rate limits below: an email signup is not a
      // Groq call and must never be blocked by (or count against) that budget.
      if (url.pathname === "/v1/waitlist") {
        if (request.method === "OPTIONS") return preflight(request);
        if (request.method === "POST") return await handleWaitlist(request, env);
        return json({ error: "method_not_allowed" }, 405);
      }

      // Anonymous product analytics from the apps, forwarded server-side to
      // PostHog. Routed through the Worker on purpose: no third-party analytics
      // SDK ever ships inside the privacy-first app, and the allow-list below
      // means content/PII can never ride through. Handled BEFORE the Groq cap —
      // an event is not a Groq call and must not count against that budget.
      if (url.pathname === "/v1/event") {
        if (request.method === "OPTIONS") return preflight(request);
        if (request.method === "POST") return await handleEvent(request, env, ctx);
        return json({ error: "method_not_allowed" }, 405);
      }

      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

      // Global spend circuit-breaker: hard stop if the day's request budget is spent.
      if (await overGlobalCap(env)) return json({ error: "service_busy" }, 503);

      // Per-client rate limiting (device id + IP), best-effort via KV.
      const deviceId = (request.headers.get("X-Device-Id") || "anon").slice(0, 64);
      const ip = request.headers.get("CF-Connecting-IP") || "0.0.0.0";
      if (await rateLimited(env, deviceId, ip)) return json({ error: "rate_limited" }, 429);

      if (url.pathname === "/v1/cleanup") return await handleCleanup(request, env, ctx);
      if (url.pathname === "/v1/transcribe") return await handleTranscribe(request, env, ctx);
      if (url.pathname === "/v1/dictate") return await handleDictate(request, env, ctx);
      return json({ error: "not_found" }, 404);
    } catch (e) {
      return json({ error: "server_error", detail: String(e).slice(0, 200) }, 500);
    }
  },
};

// ---- Handlers ---------------------------------------------------------------

async function handleCleanup(request, env, ctx) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.text !== "string" || !body.text.trim()) {
    return json({ error: "missing_text" }, 400);
  }
  const system = typeof body.system === "string" ? body.system : "";
  const requested = typeof body.model === "string" ? body.model : null;
  const r = await cleanUp(env, ctx, system, body.text, requested);
  if (r.text) return json({ text: r.text, model: r.model, timing: r.timing });
  if (r.status) {
    return json({ error: "groq_error", status: r.status, detail: r.detail, timing: r.timing }, 502);
  }
  return json({ error: r.error, timing: r.timing }, 502);
}

// One chat request body. gpt-oss models reason before answering; "low" keeps
// that to a few dozen tokens, which is the difference between ~0.4 s and several
// seconds on Groq for a paragraph of cleanup.
function chatBody(model, system, text, withReasoningEffort) {
  const b = {
    model,
    temperature: 0.1,
    max_tokens: 1500,
    messages: [
      { role: "system", content: system },
      { role: "user", content: text },
    ],
  };
  if (withReasoningEffort && model.startsWith("openai/gpt-oss")) b.reasoning_effort = "low";
  return b;
}

// Run cleanup across CLEANUP_MODELS (a requested model first), bounded by
// CLEANUP_BUDGET_MS in total. Returns { text, model, timing } on success, or
// { error | status+detail, timing } when nothing usable came back.
// timing = { cleanup_ms, attempts: ["model:outcome:ms", ...] } so the app's log
// shows exactly where the time went.
async function cleanUp(env, ctx, system, text, requested) {
  const models = requested
    ? [requested, ...CLEANUP_MODELS.filter((m) => m !== requested)]
    : CLEANUP_MODELS;
  const started = Date.now();
  const attempts = [];
  const timing = () => ({ cleanup_ms: Date.now() - started, attempts });
  let error = "no_model";

  for (const model of models) {
    let withEffort = true;
    for (let pass = 0; pass < 2; pass++) {
      const left = CLEANUP_BUDGET_MS - (Date.now() - started);
      if (left < 300) {
        attempts.push(`${model}:budget`);
        return { error: "cleanup_timeout", timing: timing() };
      }
      const t0 = Date.now();
      let resp;
      try {
        resp = await fetch(`${GROQ_BASE}/chat/completions`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.GROQ_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(chatBody(model, system, text, withEffort)),
          signal: AbortSignal.timeout(left),
        });
      } catch (e) {
        attempts.push(`${model}:timeout:${Date.now() - t0}`);
        return { error: "cleanup_timeout", timing: timing() };
      }
      if (resp.ok) {
        const data = await resp.json().catch(() => null);
        const out = data?.choices?.[0]?.message?.content?.trim() ?? "";
        attempts.push(`${model}:${out ? "ok" : "empty"}:${Date.now() - t0}`);
        if (out) {
          ctx.waitUntil(bumpSpend(env));
          return { text: out, model, timing: timing() };
        }
        error = "empty_completion";
        break; // next model
      }
      const errText = await resp.text();
      attempts.push(`${model}:${resp.status}:${Date.now() - t0}`);
      // If Groq ever stops accepting reasoning_effort for a model, retry that
      // model once without it rather than losing the model.
      if (resp.status === 400 && withEffort && errText.includes("reasoning")) {
        withEffort = false;
        continue;
      }
      // A 4xx naming the model = decommissioned / no access / rate-limited on
      // this model -> try the next model.
      if (resp.status >= 400 && resp.status < 500 && errText.includes("model")) {
        error = "model_unavailable";
        break;
      }
      return { status: resp.status, detail: errText.slice(0, 300), timing: timing() };
    }
  }
  return { error, timing: timing() };
}

async function handleTranscribe(request, env, ctx) {
  // Pass the multipart form straight through to Groq, swapping in the server key.
  const form = await request.formData().catch(() => null);
  if (!form || !form.get("file")) return json({ error: "missing_file" }, 400);

  const out = new FormData();
  out.set("file", form.get("file"), "audio.wav");
  out.set("model", form.get("model") || "whisper-large-v3-turbo");
  out.set("response_format", "json");
  out.set("temperature", form.get("temperature") || "0");
  if (form.get("language")) out.set("language", form.get("language"));
  if (form.get("prompt")) out.set("prompt", form.get("prompt"));

  const resp = await fetch(`${GROQ_BASE}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: out,
  });
  if (!resp.ok) {
    const detail = await resp.text();
    return json({ error: "groq_error", status: resp.status, detail: detail.slice(0, 300) }, 502);
  }
  const data = await resp.json();
  ctx.waitUntil(bumpSpend(env));
  return json({ text: (data?.text ?? "").trim() });
}

// The premium fast path: transcribe AND clean up in ONE request, so the phone
// makes a single round trip instead of two. Both Groq calls run server-side, where
// the hop to Groq is cheap. Returns { raw, text, cleaned } — the app runs its own
// safety guards on (raw, text), so a bad cleanup can never overwrite the words.
async function handleDictate(request, env, ctx) {
  const form = await request.formData().catch(() => null);
  if (!form || !form.get("file")) return json({ error: "missing_file" }, 400);

  // 1) Transcribe.
  const tf = new FormData();
  tf.set("file", form.get("file"), "audio.wav");
  tf.set("model", form.get("model") || "whisper-large-v3-turbo");
  tf.set("response_format", "json");
  tf.set("temperature", "0");
  if (form.get("language")) tf.set("language", form.get("language"));
  if (form.get("prompt")) tf.set("prompt", form.get("prompt"));

  const w0 = Date.now();
  const tr = await fetch(`${GROQ_BASE}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: tf,
  });
  const whisper_ms = Date.now() - w0;
  if (!tr.ok) {
    const detail = await tr.text();
    return json({ error: "groq_error", status: tr.status, detail: detail.slice(0, 300),
                  timing: { whisper_ms } }, 502);
  }
  const traw = await tr.json();
  const raw = (traw?.text ?? "").trim();
  ctx.waitUntil(bumpSpend(env));
  if (!raw) return json({ raw: "", text: "", cleaned: false, timing: { whisper_ms } });

  // 2) Clean up (best effort). If every model fails, return the raw transcript so
  // the user still gets their words; the app decides what to do with cleaned=false.
  const system = typeof form.get("system") === "string" ? form.get("system") : "";
  if (!system) return json({ raw, text: raw, cleaned: false, timing: { whisper_ms } });

  const requested = form.get("cleanup_model");
  const r = await cleanUp(env, ctx, system, raw, typeof requested === "string" ? requested : null);
  const timing = { whisper_ms, ...r.timing, model: r.model ?? null };
  if (r.text) return json({ raw, text: r.text, cleaned: true, timing });
  return json({ raw, text: raw, cleaned: false, timing });
}

// ---- Waitlist ---------------------------------------------------------------
// Stores "notify me when iPhone launches" emails in KV (key `wl:<email>`), plus a
// running `wl:count`. Export the list any time with:
//   npx wrangler kv key list --binding RL --prefix "wl:" | grep -o 'wl:[^"]*@[^"]*'
// No third-party email service needed to COLLECT; to SEND the launch email, export
// and paste into any mailer (or wire one in later).

const ALLOWED_ORIGINS = new Set([
  "https://trydictator.com",
  "https://www.trydictator.com",
  "https://giddyuptiger.github.io",
]);

function corsFor(request) {
  const origin = request.headers.get("Origin") || "";
  const allow = ALLOWED_ORIGINS.has(origin) ? origin : "https://trydictator.com";
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Vary": "Origin",
  };
}

function preflight(request) {
  return new Response(null, { status: 204, headers: corsFor(request) });
}

function jsonCors(obj, status, request) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...corsFor(request) },
  });
}

async function handleWaitlist(request, env) {
  const body = await request.json().catch(() => null);
  if (!body) return jsonCors({ error: "bad_request" }, 400, request);

  // Honeypot: a hidden field real users never fill. If it's set, silently accept
  // (so the bot thinks it worked) but store nothing.
  if (typeof body.hp === "string" && body.hp.trim() !== "") {
    return jsonCors({ ok: true }, 200, request);
  }

  const email = (typeof body.email === "string" ? body.email : "").trim().toLowerCase();
  if (email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return jsonCors({ error: "invalid_email" }, 400, request);
  }

  if (env.RL) {
    // Per-IP flood guard: at most 10 signups/minute from one address.
    const ip = request.headers.get("CF-Connecting-IP") || "0.0.0.0";
    const minute = Math.floor(Date.now() / 60000);
    if ((await incr(env, `wl:rl:${ip}:${minute}`, 120)) > 10) {
      return jsonCors({ error: "rate_limited" }, 429, request);
    }

    const key = `wl:${email}`;
    if (!(await env.RL.get(key))) {
      const ref = (typeof body.ref === "string" ? body.ref : "site").slice(0, 40);
      await env.RL.put(key, JSON.stringify({ ts: Date.now(), ref })); // no TTL: keep it
      const c = parseInt((await env.RL.get("wl:count")) || "0", 10) + 1;
      await env.RL.put("wl:count", String(c));
    }
  }

  return jsonCors({ ok: true }, 200, request);
}

// ---- Product analytics (anonymous, allow-listed) ----------------------------
// The apps POST { event, distinct_id, properties } here and the Worker forwards
// to PostHog with the project key (kept server-side). Two safety rails:
//   1. Only event names on ALLOWED_EVENTS are forwarded, so a leaked endpoint
//      can't be turned into an arbitrary firehose and no free text can ride in
//      as an event name.
//   2. Only primitive values under an allow-listed set of property keys are
//      forwarded — never a transcript, never anything user-typed. distinct_id is
//      the app's random per-install id (SharedStore.deviceID), never an email.
// Requires two Worker vars: POSTHOG_KEY (the phc_ project key) and, optionally,
// POSTHOG_HOST (defaults to US cloud, matching the account GRDN/Yonda use). If
// POSTHOG_KEY is unset this no-ops.

const ALLOWED_EVENTS = new Set([
  "app_opened",
  "onboarding_completed",
  "keyboard_full_access_granted",
  "first_dictation",
  "dictation_completed",
  "mode_changed",
  "engine_changed",
  "mac_app_launched",
  "mac_first_dictation",
]);

const ALLOWED_EVENT_PROPS = ["platform", "app_version", "mode", "engine", "value"];

async function handleEvent(request, env, ctx) {
  const body = await request.json().catch(() => null);
  if (!body || typeof body.event !== "string") {
    return jsonCors({ error: "bad_request" }, 400, request);
  }

  const event = body.event.slice(0, 64);
  // Unknown event -> accept silently (don't help a prober map the allow-list),
  // but forward nothing. Also no-op if analytics isn't configured.
  if (!ALLOWED_EVENTS.has(event) || !env.POSTHOG_KEY) {
    return jsonCors({ ok: true }, 200, request);
  }

  const distinctId = (typeof body.distinct_id === "string" ? body.distinct_id : "anon").slice(0, 64);

  const props = { $lib: "dictator-app" };
  if (body.properties && typeof body.properties === "object") {
    for (const k of ALLOWED_EVENT_PROPS) {
      const v = body.properties[k];
      if (typeof v === "string") props[k] = v.slice(0, 64);
      else if (typeof v === "number" || typeof v === "boolean") props[k] = v;
    }
  }

  const host = env.POSTHOG_HOST || "https://us.i.posthog.com";
  // Best-effort and fire-and-forget: analytics must never block or fail the app.
  ctx.waitUntil(
    fetch(`${host}/capture/`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: env.POSTHOG_KEY, event, distinct_id: distinctId, properties: props }),
    }).catch(() => {})
  );

  return jsonCors({ ok: true }, 200, request);
}

// ---- Rate limiting + spend cap (KV, best-effort) ----------------------------
// NOTE: KV is eventually consistent, so these counters are approximate — fine for
// coarse abuse bounding. For strict per-user metering/billing, move to a Durable
// Object (see README).

async function rateLimited(env, deviceId, ip) {
  if (!env.RL) return false; // no KV bound yet (local dev) -> don't block
  const minute = Math.floor(Date.now() / 60000);
  const devMax = parseInt(env.DEVICE_RPM || "20", 10);
  const ipMax = parseInt(env.IP_RPM || "40", 10);
  const dev = await incr(env, `rl:d:${deviceId}:${minute}`, 90);
  if (dev > devMax) return true;
  const ipc = await incr(env, `rl:i:${ip}:${minute}`, 90);
  if (ipc > ipMax) return true;
  return false;
}

async function overGlobalCap(env) {
  if (!env.RL) return false;
  const cap = parseInt(env.GLOBAL_DAILY_CAP || "50000", 10);
  const day = new Date().toISOString().slice(0, 10);
  const n = parseInt((await env.RL.get(`spend:${day}`)) || "0", 10);
  return n >= cap;
}

async function bumpSpend(env) {
  if (!env.RL) return;
  const day = new Date().toISOString().slice(0, 10);
  await incr(env, `spend:${day}`, 60 * 60 * 48);
}

async function incr(env, key, ttlSeconds) {
  const cur = parseInt((await env.RL.get(key)) || "0", 10);
  const next = cur + 1;
  await env.RL.put(key, String(next), { expirationTtl: ttlSeconds });
  return next;
}

// ---- utils ------------------------------------------------------------------

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
