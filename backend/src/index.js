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

// Cleanup model fallback order (mirrors the app's list): try cheap/fast first, fall
// forward if Groq has decommissioned one.
const CLEANUP_MODELS = [
  "llama-3.1-8b-instant",
  "openai/gpt-oss-20b",
  "meta-llama/llama-4-scout-17b-16e-instruct",
  "gemma2-9b-it",
  "llama-3.3-70b-versatile",
];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/healthz") {
        return json({ ok: true });
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
  const models = requested ? [requested, ...CLEANUP_MODELS] : CLEANUP_MODELS;

  let lastErr = "no_model";
  for (const model of models) {
    const resp = await fetch(`${GROQ_BASE}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GROQ_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        temperature: 0.1,
        max_tokens: 1500,
        messages: [
          { role: "system", content: system },
          { role: "user", content: body.text },
        ],
      }),
    });
    if (resp.ok) {
      const data = await resp.json();
      const text = data?.choices?.[0]?.message?.content?.trim() ?? "";
      if (text) {
        ctx.waitUntil(bumpSpend(env));
        return json({ text, model });
      }
      lastErr = "empty_completion";
      continue;
    }
    const errText = await resp.text();
    // A 4xx naming the model = decommissioned/no access -> try the next model.
    if (resp.status >= 400 && resp.status < 500 && errText.includes("model")) {
      lastErr = "model_unavailable";
      continue;
    }
    return json({ error: "groq_error", status: resp.status, detail: errText.slice(0, 300) }, 502);
  }
  return json({ error: lastErr }, 502);
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

  const tr = await fetch(`${GROQ_BASE}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` },
    body: tf,
  });
  if (!tr.ok) {
    const detail = await tr.text();
    return json({ error: "groq_error", status: tr.status, detail: detail.slice(0, 300) }, 502);
  }
  const traw = await tr.json();
  const raw = (traw?.text ?? "").trim();
  ctx.waitUntil(bumpSpend(env));
  if (!raw) return json({ raw: "", text: "", cleaned: false });

  // 2) Clean up (best effort). If every model fails, return the raw transcript so
  // the user still gets their words; the app decides what to do with cleaned=false.
  const system = typeof form.get("system") === "string" ? form.get("system") : "";
  if (!system) return json({ raw, text: raw, cleaned: false });

  const requested = form.get("cleanup_model");
  const models = requested ? [requested, ...CLEANUP_MODELS] : CLEANUP_MODELS;
  for (const model of models) {
    const resp = await fetch(`${GROQ_BASE}/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GROQ_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        temperature: 0.1,
        max_tokens: 1500,
        messages: [
          { role: "system", content: system },
          { role: "user", content: raw },
        ],
      }),
    });
    if (resp.ok) {
      const data = await resp.json();
      const text = data?.choices?.[0]?.message?.content?.trim() ?? "";
      if (text) {
        ctx.waitUntil(bumpSpend(env));
        return json({ raw, text, cleaned: true });
      }
      continue; // empty completion -> try the next model
    }
    const errText = await resp.text();
    if (resp.status >= 400 && resp.status < 500 && errText.includes("model")) {
      continue; // decommissioned/no access -> next model
    }
    break; // a real error -> stop trying, fall back to raw below
  }
  return json({ raw, text: raw, cleaned: false });
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
