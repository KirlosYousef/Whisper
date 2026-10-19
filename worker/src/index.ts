import { DurableObject } from "cloudflare:workers";
import { Buffer } from "node:buffer";
import { APPLE_ROOT_CA_G2, APPLE_ROOT_CA_G3 } from "./apple-roots";
import { verifyRevenueCatEntitlement } from "./revenuecat-entitlement";
import { decodeBase64, encodeBase64, pcm16DurationMs, sliceUncoveredAudio } from "./realtime-audio";
import { handleRevenueCatWebhook } from "./revenuecat-webhook";
import { ACCESS_POLICY, canReserveUsage, remainingUsage, usageAllowance } from "./usage-policy";

export interface Env {
  OPENAI_API_KEY: string;
  USAGE_SESSION_SECRET?: string;
  TRIAL_USAGE: DurableObjectNamespace<TrialUsageGateway>;
  REVENUECAT_WEBHOOK_AUTH_TOKEN?: string;
  REVENUECAT_APP_ID?: string;
  REVENUECAT_SECRET_API_KEY?: string;
  MIXPANEL_PROJECT_TOKEN?: string;
  /** Overrides the OpenAI origin; only set by the local test harness. */
  OPENAI_API_BASE?: string;
}

const OPENAI_API = "https://api.openai.com";

function openAIBase(env: Env): string {
  return env.OPENAI_API_BASE ?? OPENAI_API;
}
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const APP_SESSION_TTL_SECONDS = 5 * 60;
const APP_STORE_PRODUCTS = new Set([
  "KirlosYousef.Whisper.AnnualThreeDayTrial",
  "KirlosYousef.Whisper.AnnualUnlimited",
]);
const ALLOWED_HTTP_ROUTES = new Map([
  ["/v1/audio/transcriptions", "/v1/audio/transcriptions"],
  ["/v1/chat/completions", "/v1/chat/completions"],
]);

type AccessClaims = {
  sub: string;
  product: string;
  accessTier?: "trial" | "paid";
  exp: number;
  demo?: boolean;
};

function corsHeaders(): Headers {
  return new Headers({
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Usage-Operation-ID, X-Usage-Operation-Type, X-Audio-Session-ID, X-Audio-Start-MS",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  });
}

function jsonError(message: string, status: number): Response {
  const headers = corsHeaders();
  headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify({ error: message }), { status, headers });
}

function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  corsHeaders().forEach((value, key) => headers.set(key, value));
  return new Response(response.body, { status: response.status, headers });
}

function openAIHeaders(request: Request, apiKey: string): Headers {
  const headers = new Headers(request.headers);
  headers.delete("authorization");
  headers.delete("host");
  headers.delete("content-length");
  headers.delete("x-usage-operation-id");
  headers.delete("x-audio-session-id");
  headers.delete("x-audio-start-ms");
  headers.delete("x-usage-operation-type");
  headers.set("Authorization", `Bearer ${apiKey}`);
  return headers;
}

function decodeBase64URL(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

function encodeBase64URL(value: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 0x8000) {
    binary += String.fromCharCode(...value.subarray(offset, Math.min(offset + 0x8000, value.length)));
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function signAccessToken(claims: AccessClaims, secret: string): Promise<string> {
  const header = encodeBase64URL(new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = encodeBase64URL(new TextEncoder().encode(JSON.stringify(claims)));
  const unsigned = `${header}.${payload}`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${encodeBase64URL(new Uint8Array(signature))}`;
}

async function verifyAccessToken(value: string, secret: string): Promise<AccessClaims | undefined> {
  const parts = value.split(".");
  if (parts.length !== 3) return undefined;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  let signature: Uint8Array;
  let claims: AccessClaims;
  try {
    signature = decodeBase64URL(parts[2]);
    claims = JSON.parse(new TextDecoder().decode(decodeBase64URL(parts[1]))) as AccessClaims;
  } catch {
    return undefined;
  }
  const valid = await crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  const validProduct = APP_STORE_PRODUCTS.has(claims.product) && ["trial", "paid"].includes(claims.accessTier ?? "") ||
    (claims.product === "onboarding-demo" && claims.demo === true && claims.sub.startsWith("demo:"));
  if (!valid || typeof claims.sub !== "string" || !claims.sub || !validProduct ||
      typeof claims.exp !== "number" || claims.exp <= Math.floor(Date.now() / 1000)) return undefined;
  return claims;
}

function usageObject(env: Env, originalTransactionId: string): DurableObjectStub<TrialUsageGateway> {
  return env.TRIAL_USAGE.get(env.TRIAL_USAGE.idFromName(originalTransactionId));
}

function validateWavDurationMs(data: ArrayBuffer): number | undefined {
  const view = new DataView(data);
  if (data.byteLength < 44 || view.getUint32(0, false) !== 0x52494646 || view.getUint32(8, false) !== 0x57415645) return undefined;
  let offset = 12;
  let sampleRate: number | undefined;
  let blockAlign: number | undefined;
  let byteRate: number | undefined;
  let encoding: number | undefined;
  let channels: number | undefined;
  let bitDepth: number | undefined;
  let dataBytes: number | undefined;
  while (offset + 8 <= data.byteLength) {
    const id = view.getUint32(offset, false);
    const size = view.getUint32(offset + 4, true);
    const bodyOffset = offset + 8;
    if (bodyOffset + size > data.byteLength) return undefined;
    if (id === 0x666d7420 && size >= 16) {
      encoding = view.getUint16(bodyOffset, true);
      channels = view.getUint16(bodyOffset + 2, true);
      sampleRate = view.getUint32(bodyOffset + 4, true);
      byteRate = view.getUint32(bodyOffset + 8, true);
      blockAlign = view.getUint16(bodyOffset + 12, true);
      bitDepth = view.getUint16(bodyOffset + 14, true);
    }
    if (id === 0x64617461) dataBytes = size;
    offset = bodyOffset + size + (size % 2);
  }
  if (encoding !== 1 || channels !== 1 || bitDepth !== 16 || !sampleRate || !blockAlign ||
      blockAlign !== 2 || byteRate !== sampleRate * blockAlign || !dataBytes || dataBytes % blockAlign !== 0) return undefined;
  const duration = Math.ceil((dataBytes / byteRate) * 1000);
  return Number.isSafeInteger(duration) && duration > 0 ? duration : undefined;
}

async function verifyTransaction(signedTransaction: string) {
  const { Environment, SignedDataVerifier } = await import("@apple/app-store-server-library");
  const bundleID = "KirlosYousef.Whisper";
  const appAppleID = 6748306699;
  const roots = [APPLE_ROOT_CA_G2, APPLE_ROOT_CA_G3].map(value => Buffer.from(value, "base64"));
  const environments = [Environment.PRODUCTION, Environment.SANDBOX];
  for (const environment of environments) {
    try {
      const verifier = new SignedDataVerifier(roots, false, environment, bundleID, environment === Environment.PRODUCTION ? appAppleID : undefined);
      const transaction = await verifier.verifyAndDecodeTransaction(signedTransaction);
      if (!transaction.originalTransactionId || !APP_STORE_PRODUCTS.has(transaction.productId ?? "")) return undefined;
      if (transaction.bundleId !== bundleID || transaction.revocationDate != null ||
          typeof transaction.expiresDate !== "number" || transaction.expiresDate <= Date.now()) return undefined;
      return transaction;
    } catch {
      // A production JWS is expected to fail verification against the sandbox certificate chain, and vice versa.
    }
  }
  return undefined;
}

function accessTierForTransaction(transaction: Awaited<ReturnType<typeof verifyTransaction>>): "trial" | "paid" {
  if (transaction?.productId === "KirlosYousef.Whisper.AnnualThreeDayTrial" &&
      transaction.offerDiscountType === "FREE_TRIAL") return "trial";
  return "paid";
}

async function createUsageSession(request: Request, env: Env): Promise<Response> {
  if (!env.USAGE_SESSION_SECRET || !env.REVENUECAT_SECRET_API_KEY) return jsonError("Subscription verification is not configured.", 503);
  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return jsonError("Invalid request.", 400);
  }
  const body = payload as { appUserID?: unknown; signedTransactions?: unknown };
  if (typeof body?.appUserID !== "string" || body.appUserID.length < 1 || body.appUserID.length > 256 ||
      !Array.isArray(body?.signedTransactions) || body.signedTransactions.length < 1 || body.signedTransactions.length > 10 ||
      body.signedTransactions.some(value => typeof value !== "string" || value.length > 16_384)) {
    return jsonError("A valid App Store transaction and RevenueCat customer are required.", 400);
  }
  const transactions = await Promise.all((body.signedTransactions as string[]).map(verifyTransaction));
  const verified = transactions.filter((item): item is NonNullable<typeof item> => Boolean(item?.originalTransactionId && item.productId && item.expiresDate));
  if (verified.length === 0) return jsonError("Subscription could not be verified.", 403);
  const originalIDs = new Set(verified.map(item => item.originalTransactionId));
  if (originalIDs.size !== 1) return jsonError("Active subscription ownership could not be resolved.", 403);
  // Prefer the no-trial annual product if both transactions are temporarily present during a plan change.
  const transaction = verified.sort((a, b) => {
    const paidDifference = Number(accessTierForTransaction(b) === "paid") - Number(accessTierForTransaction(a) === "paid");
    return paidDifference || (b.expiresDate ?? 0) - (a.expiresDate ?? 0);
  })[0];
  if (!transaction.originalTransactionId || !transaction.productId || !transaction.expiresDate) return jsonError("Subscription could not be verified.", 403);
  let revenueCatActive: boolean;
  try {
    revenueCatActive = await verifyRevenueCatEntitlement(body.appUserID, transaction, env.REVENUECAT_SECRET_API_KEY);
  } catch {
    return jsonError("Your subscription is still being verified. Try again shortly.", 503);
  }
  if (!revenueCatActive) return jsonError("RevenueCat could not verify this active subscription.", 403);

  const expires = Math.min(Math.floor(transaction.expiresDate / 1000), Math.floor(Date.now() / 1000) + APP_SESSION_TTL_SECONDS);
  const accessTier = accessTierForTransaction(transaction);
  const claims: AccessClaims = { sub: transaction.originalTransactionId, product: transaction.productId, accessTier, exp: expires };
  const stub = usageObject(env, transaction.originalTransactionId);
  const syncResponse = await stub.fetch("https://usage.internal/sync", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ product: transaction.productId, accessTier, expiresAt: transaction.expiresDate }),
  });
  if (!syncResponse.ok) return jsonError("Subscription state could not be saved. Try again.", 503);
  const usage = await syncResponse.json();
  return Response.json({ token: await signAccessToken(claims, env.USAGE_SESSION_SECRET), usage }, { headers: corsHeaders() });
}

async function createDemoSession(request: Request, env: Env): Promise<Response> {
  if (!env.USAGE_SESSION_SECRET) return jsonError("Usage service is not configured.", 503);
  let payload: unknown;
  try { payload = await request.json(); } catch { return jsonError("Invalid request.", 400); }
  const demoID = (payload as { demoID?: unknown })?.demoID;
  if (typeof demoID !== "string" || !/^[0-9a-f-]{36}$/i.test(demoID)) return jsonError("A valid demo session is required.", 400);
  const subject = `demo:${demoID}`;
  const stub = usageObject(env, subject);
  const response = await stub.fetch("https://usage.internal/demo", { method: "POST" });
  if (!response.ok) return jsonError("Demo session could not be created.", 503);
  return Response.json({
    token: await signAccessToken({ sub: subject, product: "onboarding-demo", demo: true, exp: Math.floor(Date.now() / 1000) + 300 }, env.USAGE_SESSION_SECRET),
    usage: await response.json(),
  }, { headers: corsHeaders() });
}

async function authorizedUsage(request: Request, env: Env): Promise<{ stub: DurableObjectStub<TrialUsageGateway>; claims: AccessClaims } | Response> {
  if (!env.USAGE_SESSION_SECRET) return jsonError("Usage service is not configured.", 503);
  const authorization = request.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return jsonError("Update Revera to continue processing audio.", 426);
  const claims = await verifyAccessToken(authorization.slice(7), env.USAGE_SESSION_SECRET);
  if (!claims) return jsonError("Subscription verification expired. Reopen Revera while online.", 401);
  const stub = usageObject(env, claims.sub);
  const stateResponse = await stub.fetch("https://usage.internal/state", { method: "GET" });
  if (!stateResponse.ok) return jsonError("Subscription state could not be verified.", 503);
  const state = await stateResponse.json() as { active?: boolean; paid?: boolean };
  if (!state.active) return jsonError("Subscription has expired.", 403);
  return { stub, claims };
}

export class TrialUsageGateway extends DurableObject<Env> {
  private readonly sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = this.ctx.storage.sql;
    this.sql.exec("CREATE TABLE IF NOT EXISTS subscription (id INTEGER PRIMARY KEY CHECK(id = 1), product TEXT NOT NULL, access_tier TEXT NOT NULL, expires_at_ms INTEGER NOT NULL)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY CHECK(id = 1), trial_used_ms INTEGER NOT NULL DEFAULT 0, trial_reserved_ms INTEGER NOT NULL DEFAULT 0, paid_period_start_ms INTEGER, paid_used_ms INTEGER NOT NULL DEFAULT 0, paid_reserved_ms INTEGER NOT NULL DEFAULT 0, demo_used_ms INTEGER NOT NULL DEFAULT 0, demo_reserved_ms INTEGER NOT NULL DEFAULT 0, demo_chat_count INTEGER NOT NULL DEFAULT 0)");
    this.sql.exec("INSERT OR IGNORE INTO usage (id, trial_used_ms, paid_used_ms) VALUES (1, 0, 0)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS operations (operation_id TEXT PRIMARY KEY, audio_session_id TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, consumed_ms INTEGER NOT NULL, accounting_type TEXT NOT NULL, state TEXT NOT NULL, created_at_ms INTEGER NOT NULL, response_status INTEGER, response_content_type TEXT, response_body TEXT)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS audio_ranges (audio_session_id TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, PRIMARY KEY(audio_session_id, start_ms, end_ms))");
    this.sql.exec("CREATE TABLE IF NOT EXISTS audio_jobs (audio_session_id TEXT NOT NULL, kind TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, operation_id TEXT NOT NULL UNIQUE, PRIMARY KEY(audio_session_id, kind, start_ms, end_ms))");
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/sync" && request.method === "POST") {
      const body = await request.json() as { product?: string; accessTier?: string; expiresAt?: number };
      if (!body.product || !APP_STORE_PRODUCTS.has(body.product) || !["trial", "paid"].includes(body.accessTier ?? "") || !body.expiresAt || body.expiresAt <= Date.now()) return jsonError("Invalid subscription state.", 400);
      this.sql.exec("INSERT INTO subscription (id, product, access_tier, expires_at_ms) VALUES (1, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET product=excluded.product, access_tier=excluded.access_tier, expires_at_ms=excluded.expires_at_ms", body.product, body.accessTier, body.expiresAt);
      return Response.json(await this.snapshot());
    }
    if (url.pathname === "/state" && request.method === "GET") return Response.json(await this.snapshot());
    if (url.pathname === "/demo" && request.method === "POST") {
      this.sql.exec("INSERT INTO subscription (id, product, access_tier, expires_at_ms) VALUES (1, 'onboarding-demo', 'demo', ?) ON CONFLICT(id) DO UPDATE SET product='onboarding-demo', access_tier='demo', expires_at_ms=MAX(subscription.expires_at_ms, excluded.expires_at_ms)", Date.now() + 300_000);
      return Response.json(await this.snapshot());
    }
    if (url.pathname === "/demo-chat" && request.method === "POST") {
      const subscription = this.sql.exec<{ product: string; access_tier: string; expires_at_ms: number }>("SELECT product, access_tier, expires_at_ms FROM subscription WHERE id=1").one();
      if (subscription?.product !== "onboarding-demo" || subscription.expires_at_ms <= Date.now()) return jsonError("Demo session has expired.", 402);
      const count = this.sql.exec<{ demo_chat_count: number }>("SELECT demo_chat_count FROM usage WHERE id=1").one()?.demo_chat_count ?? 0;
      if (count >= 8) return jsonError("The onboarding demo limit has been reached.", 402);
      this.sql.exec("UPDATE usage SET demo_chat_count=demo_chat_count+1 WHERE id=1");
      return Response.json({ accepted: true });
    }
    if (url.pathname === "/consume" && request.method === "POST") {
      const body = await request.json() as UsageRequest;
      try {
        return Response.json(this.consume(body));
      } catch (error) {
        if (error instanceof UsageLimitError) return Response.json({ error: "trial_exhausted", ...await this.snapshot() }, { status: 402 });
        if (error instanceof PendingUsageOperationError) return jsonError("This processing request is already running. Retry it in a moment.", 409);
        if (error instanceof DuplicateAudioJobError) return jsonError("This audio has already been processed for this task.", 409);
        return jsonError("Usage could not be recorded.", 500);
      }
    }
    if (url.pathname === "/complete" && request.method === "POST") {
      const body = await request.json() as { operationID?: string; status?: number; contentType?: string; responseBody?: string };
      return this.completeOperation(body);
    }
    if (url.pathname === "/release" && request.method === "POST") {
      const body = await request.json() as { operationID?: string };
      return this.releaseOperation(body.operationID);
    }
    if (request.headers.get("Upgrade")?.toLowerCase() === "websocket") return this.startRealtime(request);
    return jsonError("Route not found.", 404);
  }

  private async snapshot() {
    this.finalizeAbandonedReservations();
    const subscription = this.sql.exec<{ product: string; access_tier: string; expires_at_ms: number }>("SELECT product, access_tier, expires_at_ms FROM subscription WHERE id=1").toArray()[0];
    const usage = this.sql.exec<{ trial_used_ms: number; trial_reserved_ms: number; paid_used_ms: number; paid_reserved_ms: number; demo_used_ms: number; demo_reserved_ms: number; paid_period_start_ms: number | null }>("SELECT trial_used_ms, trial_reserved_ms, paid_used_ms, paid_reserved_ms, demo_used_ms, demo_reserved_ms, paid_period_start_ms FROM usage WHERE id=1").toArray()[0];
    const active = Boolean(subscription && subscription.expires_at_ms > Date.now());
    const demo = active && subscription?.product === "onboarding-demo";
    const paid = active && subscription?.access_tier === "paid";
    const tier = paid ? "paid" : demo ? "demo" : "trial";
    const allowanceMs = usageAllowance(tier);
    const consumedMs = demo ? usage?.demo_used_ms ?? 0 : paid ? usage?.paid_used_ms ?? 0 : usage?.trial_used_ms ?? 0;
    const reservedMs = demo ? usage?.demo_reserved_ms ?? 0 : paid ? usage?.paid_reserved_ms ?? 0 : usage?.trial_reserved_ms ?? 0;
    return {
      state: !active ? "inactive" : demo ? "demo" : paid ? "paid" : "trial",
      active,
      paid,
      demo,
      expiresAt: subscription?.expires_at_ms ?? null,
      allowanceMs,
      consumedMs,
      reservedMs,
      remainingMs: remainingUsage(tier, consumedMs, reservedMs),
      paidPeriodStartAt: usage?.paid_period_start_ms ?? null,
      paidConsumedMs: usage?.paid_used_ms ?? 0,
      policyVersion: ACCESS_POLICY.version,
    };
  }

  private consume(body: UsageRequest): UsageSnapshot {
    const subscription = this.sql.exec<{ product: string; access_tier: string; expires_at_ms: number }>("SELECT product, access_tier, expires_at_ms FROM subscription WHERE id=1").one();
    if (!subscription || subscription.expires_at_ms <= Date.now()) throw new UsageLimitError();
    const paid = subscription.access_tier === "paid";
    const demo = subscription.product === "onboarding-demo";
    const operationID = body.operationID;
    if (!operationID || operationID.length > 128 || !body.audioSessionID || body.audioSessionID.length > 128 ||
        !Number.isSafeInteger(body.startMs) || !Number.isSafeInteger(body.durationMs) || body.startMs < 0 || body.durationMs <= 0 || body.durationMs > 86_400_000) {
      throw new Error("invalid usage operation");
    }
    const operationKind = body.operationKind ?? "transcription";
    if (!["transcription", "diarization", "realtime"].includes(operationKind)) throw new Error("invalid operation kind");
    const existing = this.sql.exec<{ consumed_ms: number; state: string; response_status: number | null; response_content_type: string | null; response_body: string | null }>(
      "SELECT consumed_ms, state, response_status, response_content_type, response_body FROM operations WHERE operation_id=?", operationID,
    ).toArray()[0];
    if (existing?.state === "released") {
      this.sql.exec("DELETE FROM audio_jobs WHERE operation_id=?", operationID);
      this.sql.exec("DELETE FROM operations WHERE operation_id=?", operationID);
    } else if (existing) {
      if (existing.state === "reserved") throw new PendingUsageOperationError();
      return {
        accepted: true,
        alreadyCounted: true,
        chargedMs: existing.consumed_ms,
        cachedResponse: existing.response_body == null ? null : {
          status: existing.response_status ?? 200,
          contentType: existing.response_content_type ?? "application/json",
          body: existing.response_body,
        },
        ...this.snapshotSync(),
      };
    }

    const startMs = body.startMs;
    const endMs = startMs + body.durationMs;
    if (operationKind !== "realtime") {
      const duplicate = this.sql.exec<{ operation_id: string }>(
        "SELECT operation_id FROM audio_jobs WHERE audio_session_id=? AND kind=? AND start_ms < ? AND end_ms > ? LIMIT 1",
        body.audioSessionID, operationKind, endMs, startMs,
      ).toArray()[0];
      if (duplicate) throw new DuplicateAudioJobError();
    }
    const overlaps = this.sql.exec<{ start_ms: number; end_ms: number }>(
      "SELECT start_ms, end_ms FROM audio_ranges WHERE audio_session_id=? AND start_ms < ? AND end_ms > ? ORDER BY start_ms",
      body.audioSessionID, endMs, startMs,
    ).toArray();
    const uncoveredRanges: Array<{ startMs: number; endMs: number }> = [];
    let cursor = startMs;
    for (const range of overlaps) {
      if (range.start_ms > cursor) uncoveredRanges.push({ startMs: cursor, endMs: Math.min(endMs, range.start_ms) });
      cursor = Math.max(cursor, Math.min(endMs, range.end_ms));
      if (cursor >= endMs) break;
    }
    if (cursor < endMs) uncoveredRanges.push({ startMs: cursor, endMs });
    const uniqueMs = uncoveredRanges.reduce((sum, range) => sum + range.endMs - range.startMs, 0);
    const usage = this.sql.exec<{
      trial_used_ms: number; trial_reserved_ms: number; paid_used_ms: number; paid_reserved_ms: number; demo_used_ms: number; demo_reserved_ms: number;
    }>("SELECT trial_used_ms, trial_reserved_ms, paid_used_ms, paid_reserved_ms, demo_used_ms, demo_reserved_ms FROM usage WHERE id=1").one();
    const current = demo ? usage?.demo_used_ms ?? 0 : paid ? usage?.paid_used_ms ?? 0 : usage?.trial_used_ms ?? 0;
    const reserved = demo ? usage?.demo_reserved_ms ?? 0 : paid ? usage?.paid_reserved_ms ?? 0 : usage?.trial_reserved_ms ?? 0;
    const tier = paid ? "paid" : demo ? "demo" : "trial";
    if (!canReserveUsage(tier, current, reserved, uniqueMs)) throw new UsageLimitError();

    const accountingType = demo ? "demo" : paid ? "paid" : "trial";
    this.sql.exec(
      "INSERT INTO operations (operation_id, audio_session_id, start_ms, end_ms, consumed_ms, accounting_type, state, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, 'reserved', ?)",
      operationID, body.audioSessionID, startMs, endMs, uniqueMs, accountingType, Date.now(),
    );
    if (operationKind !== "realtime") {
      this.sql.exec("INSERT INTO audio_jobs (audio_session_id, kind, start_ms, end_ms, operation_id) VALUES (?, ?, ?, ?, ?)", body.audioSessionID, operationKind, startMs, endMs, operationID);
    }
    if (uniqueMs > 0) {
      const reservedColumn = demo ? "demo_reserved_ms" : paid ? "paid_reserved_ms" : "trial_reserved_ms";
      this.sql.exec(`UPDATE usage SET ${reservedColumn}=${reservedColumn}+? WHERE id=1`, uniqueMs);
    }
    if (uniqueMs > 0) {
      for (const range of overlaps) this.sql.exec("DELETE FROM audio_ranges WHERE audio_session_id=? AND start_ms=? AND end_ms=?", body.audioSessionID, range.start_ms, range.end_ms);
      const mergedStart = Math.min(startMs, ...overlaps.map(range => range.start_ms));
      const mergedEnd = Math.max(endMs, ...overlaps.map(range => range.end_ms));
      this.sql.exec("INSERT INTO audio_ranges (audio_session_id, start_ms, end_ms) VALUES (?, ?, ?)", body.audioSessionID, mergedStart, mergedEnd);
    }
    return { accepted: true, alreadyCounted: false, operationID, chargedMs: uniqueMs, uncoveredRanges, ...this.snapshotSync() };
  }

  private snapshotSync() {
    const usage = this.sql.exec<{ trial_used_ms: number; trial_reserved_ms: number; paid_used_ms: number; paid_reserved_ms: number; demo_used_ms: number; demo_reserved_ms: number }>("SELECT trial_used_ms, trial_reserved_ms, paid_used_ms, paid_reserved_ms, demo_used_ms, demo_reserved_ms FROM usage WHERE id=1").toArray()[0];
    const subscription = this.sql.exec<{ product: string; access_tier: string; expires_at_ms: number }>("SELECT product, access_tier, expires_at_ms FROM subscription WHERE id=1").toArray()[0];
    const active = (subscription?.expires_at_ms ?? 0) > Date.now();
    const demo = active && subscription?.product === "onboarding-demo";
    const paid = active && subscription?.access_tier === "paid";
    const tier = paid ? "paid" : demo ? "demo" : "trial";
    const allowanceMs = usageAllowance(tier);
    const consumedMs = demo ? usage?.demo_used_ms ?? 0 : paid ? usage?.paid_used_ms ?? 0 : usage?.trial_used_ms ?? 0;
    const reservedMs = demo ? usage?.demo_reserved_ms ?? 0 : paid ? usage?.paid_reserved_ms ?? 0 : usage?.trial_reserved_ms ?? 0;
    return { state: !active ? "inactive" : demo ? "demo" : paid ? "paid" : "trial", allowanceMs, consumedMs, reservedMs, remainingMs: remainingUsage(tier, consumedMs, reservedMs), paidConsumedMs: usage?.paid_used_ms ?? 0, policyVersion: ACCESS_POLICY.version };
  }

  private completeOperation(body: { operationID?: string; status?: number; contentType?: string; responseBody?: string }): Response {
    if (!body.operationID) return jsonError("Operation ID is required.", 400);
    const operation = this.sql.exec<{ consumed_ms: number; accounting_type: string; state: string }>(
      "SELECT consumed_ms, accounting_type, state FROM operations WHERE operation_id=?", body.operationID,
    ).toArray()[0];
    if (!operation) return jsonError("Usage reservation was not found.", 404);
    if (operation.state !== "reserved") return Response.json({ accepted: true, alreadyCompleted: true });
    const reservedColumn = operation.accounting_type === "demo" ? "demo_reserved_ms" : operation.accounting_type === "paid" ? "paid_reserved_ms" : "trial_reserved_ms";
    const usedColumn = operation.accounting_type === "demo" ? "demo_used_ms" : operation.accounting_type === "paid" ? "paid_used_ms" : "trial_used_ms";
    this.sql.exec(`UPDATE usage SET ${reservedColumn}=MAX(0, ${reservedColumn}-?), ${usedColumn}=${usedColumn}+? WHERE id=1`, operation.consumed_ms, operation.consumed_ms);
    const responseBody = body.responseBody && body.responseBody.length <= 262_144 ? body.responseBody : null;
    this.sql.exec(
      "UPDATE operations SET state='completed', response_status=?, response_content_type=?, response_body=? WHERE operation_id=?",
      body.status ?? 200, body.contentType ?? "application/json", responseBody, body.operationID,
    );
    return Response.json({ accepted: true });
  }

  private releaseOperation(operationID?: string): Response {
    if (!operationID) return jsonError("Operation ID is required.", 400);
    const operation = this.sql.exec<{ consumed_ms: number; accounting_type: string; state: string; audio_session_id: string }>(
      "SELECT consumed_ms, accounting_type, state, audio_session_id FROM operations WHERE operation_id=?", operationID,
    ).toArray()[0];
    if (!operation || operation.state !== "reserved") return Response.json({ accepted: true });
    const reservedColumn = operation.accounting_type === "demo" ? "demo_reserved_ms" : operation.accounting_type === "paid" ? "paid_reserved_ms" : "trial_reserved_ms";
    this.sql.exec(`UPDATE usage SET ${reservedColumn}=MAX(0, ${reservedColumn}-?) WHERE id=1`, operation.consumed_ms);
    this.sql.exec("UPDATE operations SET state='released' WHERE operation_id=?", operationID);
    this.sql.exec("DELETE FROM audio_jobs WHERE operation_id=?", operationID);
    this.rebuildAudioRanges(operation.audio_session_id);
    return Response.json({ accepted: true });
  }

  private rebuildAudioRanges(audioSessionID: string): void {
    const operations = this.sql.exec<{ start_ms: number; end_ms: number }>(
      "SELECT start_ms, end_ms FROM operations WHERE audio_session_id=? AND state!='released' AND end_ms>start_ms ORDER BY start_ms, end_ms",
      audioSessionID,
    ).toArray();
    this.sql.exec("DELETE FROM audio_ranges WHERE audio_session_id=?", audioSessionID);
    let start: number | undefined;
    let end: number | undefined;
    for (const operation of operations) {
      if (start == null) { start = operation.start_ms; end = operation.end_ms; continue; }
      if (operation.start_ms <= end!) { end = Math.max(end!, operation.end_ms); continue; }
      this.sql.exec("INSERT INTO audio_ranges (audio_session_id, start_ms, end_ms) VALUES (?, ?, ?)", audioSessionID, start, end);
      start = operation.start_ms;
      end = operation.end_ms;
    }
    if (start != null && end != null) this.sql.exec("INSERT INTO audio_ranges (audio_session_id, start_ms, end_ms) VALUES (?, ?, ?)", audioSessionID, start, end);
  }

  private finalizeAbandonedReservations(): void {
    const expired = this.sql.exec<{ operation_id: string; consumed_ms: number; accounting_type: string }>(
      "SELECT operation_id, consumed_ms, accounting_type FROM operations WHERE state='reserved' AND created_at_ms < ?",
      Date.now() - 30 * 60_000,
    ).toArray();
    for (const operation of expired) this.completeOperation({ operationID: operation.operation_id, status: 200 });
  }

  private async startRealtime(request: Request): Promise<Response> {
    const clientSessionID = request.headers.get("X-Audio-Session-ID") ?? "";
    const audioSessionID = clientSessionID.length >= 1 && clientSessionID.length <= 128 ? clientSessionID : crypto.randomUUID();
    const offsetMs = Number(request.headers.get("X-Audio-Start-MS") ?? 0);
    if (!Number.isSafeInteger(offsetMs) || offsetMs < 0) return jsonError("Invalid audio session.", 400);

    const snapshot = await this.snapshot();
    if (!snapshot.active) return jsonError("Subscription has expired.", 403);
    if (snapshot.remainingMs === 0) return jsonError("trial_exhausted", 402);

    const upstreamURL = new URL(`${openAIBase(this.env)}/v1/realtime`);
    upstreamURL.search = new URL(request.url).search;
    const headers = new Headers({ Upgrade: "websocket", Authorization: `Bearer ${this.env.OPENAI_API_KEY}` });
    for (const name of ["Sec-WebSocket-Protocol", "OpenAI-Beta"]) {
      const value = request.headers.get(name);
      if (value) headers.set(name, value);
    }
    let upstream: WebSocket;
    try {
      const response = await fetch(upstreamURL, { headers });
      if (!response.webSocket) {
        console.error("Realtime upstream rejected the upgrade.", response.status);
        return jsonError("Realtime service unavailable.", 502);
      }
      upstream = response.webSocket;
    } catch (error) {
      console.error("Realtime upstream connection failed.", error);
      return jsonError("Realtime service unavailable.", 502);
    }

    const [client, server] = Object.values(new WebSocketPair());
    server.accept();
    upstream.accept();

    let closed = false;
    let runningOffsetMs = offsetMs;
    const closeBoth = (code: number, reason: string) => {
      if (closed) return;
      closed = true;
      closeSocket(server, code, reason);
      closeSocket(upstream, code, reason);
    };
    const forwardUpstream = (data: string | ArrayBuffer) => {
      try {
        upstream.send(data);
      } catch {
        closeBoth(1011, "Realtime connection failed.");
      }
    };

    server.addEventListener("message", event => {
      if (closed) return;
      if (typeof event.data !== "string") return forwardUpstream(event.data);
      let payload: Record<string, unknown> | null;
      try {
        payload = JSON.parse(event.data) as Record<string, unknown> | null;
      } catch {
        return forwardUpstream(event.data);
      }
      if (payload?.type !== "input_audio_buffer.append" || typeof payload.audio !== "string") return forwardUpstream(event.data);

      let bytes: Uint8Array;
      try {
        bytes = decodeBase64(payload.audio);
      } catch {
        return forwardUpstream(event.data);
      }
      if (bytes.length === 0) return;
      const { audio_start_ms: audioStartMs, ...append } = payload;
      const chunkStartMs = Number.isSafeInteger(audioStartMs) && Number(audioStartMs) >= 0 ? Number(audioStartMs) : runningOffsetMs;
      const durationMs = pcm16DurationMs(bytes.length);
      const operationID = crypto.randomUUID();
      let result: UsageSnapshot;
      try {
        result = this.consume({ operationID, audioSessionID, startMs: chunkStartMs, durationMs, operationKind: "realtime" });
      } catch (error) {
        if (error instanceof UsageLimitError) closeBoth(4409, "TRIAL_USAGE_EXHAUSTED");
        else closeBoth(1011, "Realtime usage could not be recorded.");
        return;
      }
      runningOffsetMs += durationMs;

      try {
        for (const slice of sliceUncoveredAudio(bytes, chunkStartMs, result.uncoveredRanges ?? [])) {
          upstream.send(JSON.stringify({ ...append, audio: encodeBase64(slice) }));
        }
      } catch {
        closeBoth(1011, "Realtime connection failed.");
        return;
      }
      this.completeOperation({ operationID, status: 200 });
      if (this.snapshotSync().remainingMs === 0) closeBoth(4409, "TRIAL_USAGE_EXHAUSTED");
    });
    server.addEventListener("close", event => closeBoth(event.code, event.reason));
    upstream.addEventListener("close", event => closeBoth(event.code, event.reason));
    server.addEventListener("error", () => closeBoth(1011, "Realtime connection failed."));
    upstream.addEventListener("error", () => closeBoth(1011, "Realtime connection failed."));
    upstream.addEventListener("message", event => {
      try {
        server.send(event.data);
      } catch {
        closeBoth(1011, "Realtime connection failed.");
      }
    });

    return new Response(null, { status: 101, webSocket: client });
  }
}

function closeSocket(socket: WebSocket, code: number, reason: string): void {
  const safeCode = code === 1005 ? 1000 : code === 1006 || code === 1015 ? 1011 : code;
  try {
    socket.close(safeCode, reason);
  } catch {
    // The socket may already be closed.
  }
}

type UsageRequest = { operationID: string; audioSessionID: string; startMs: number; durationMs: number; operationKind?: "transcription" | "diarization" | "realtime" };
type UsageSnapshot = {
  state: string; allowanceMs: number | null; consumedMs: number; reservedMs: number; remainingMs: number | null;
  paidConsumedMs: number; policyVersion: number; accepted?: boolean; alreadyCounted?: boolean; chargedMs?: number;
  operationID?: string; uncoveredRanges?: Array<{ startMs: number; endMs: number }>;
  cachedResponse?: { status: number; contentType: string; body: string } | null;
};
class UsageLimitError extends Error {}
class PendingUsageOperationError extends Error {}
class DuplicateAudioJobError extends Error {}

function cropWavToRanges(data: ArrayBuffer, ranges: Array<{ startMs: number; endMs: number }>): Uint8Array | undefined {
  const view = new DataView(data);
  let offset = 12;
  let format: number | undefined;
  let channels: number | undefined;
  let sampleRate: number | undefined;
  let blockAlign: number | undefined;
  let bitDepth: number | undefined;
  let audioOffset: number | undefined;
  let audioLength: number | undefined;
  while (offset + 8 <= data.byteLength) {
    const id = view.getUint32(offset, false);
    const size = view.getUint32(offset + 4, true);
    const bodyOffset = offset + 8;
    if (bodyOffset + size > data.byteLength) return undefined;
    if (id === 0x666d7420 && size >= 16) {
      format = view.getUint16(bodyOffset, true);
      channels = view.getUint16(bodyOffset + 2, true);
      sampleRate = view.getUint32(bodyOffset + 4, true);
      blockAlign = view.getUint16(bodyOffset + 12, true);
      bitDepth = view.getUint16(bodyOffset + 14, true);
    }
    if (id === 0x64617461) {
      audioOffset = bodyOffset;
      audioLength = size;
      break;
    }
    offset = bodyOffset + size + (size % 2);
  }
  if (format !== 1 || channels !== 1 || bitDepth !== 16 || !sampleRate || blockAlign !== 2 || audioOffset == null || audioLength == null) return undefined;
  const source = new Uint8Array(data, audioOffset, audioLength);
  const frameCount = Math.floor(source.length / blockAlign);
  const pieces: Uint8Array[] = [];
  for (const range of ranges) {
    const firstFrame = Math.max(0, Math.min(frameCount, Math.floor(range.startMs * sampleRate / 1_000)));
    const lastFrame = Math.max(firstFrame, Math.min(frameCount, Math.ceil(range.endMs * sampleRate / 1_000)));
    if (lastFrame > firstFrame) pieces.push(source.subarray(firstFrame * blockAlign, lastFrame * blockAlign));
  }
  const payloadLength = pieces.reduce((sum, piece) => sum + piece.length, 0);
  if (payloadLength === 0 || payloadLength + 36 > 0xffff_ffff) return undefined;
  const result = new Uint8Array(44 + payloadLength);
  const output = new DataView(result.buffer);
  const writeTag = (at: number, value: string) => result.set(new TextEncoder().encode(value), at);
  writeTag(0, "RIFF");
  output.setUint32(4, 36 + payloadLength, true);
  writeTag(8, "WAVE");
  writeTag(12, "fmt ");
  output.setUint32(16, 16, true);
  output.setUint16(20, 1, true);
  output.setUint16(22, 1, true);
  output.setUint32(24, sampleRate, true);
  output.setUint32(28, sampleRate * blockAlign, true);
  output.setUint16(32, blockAlign, true);
  output.setUint16(34, 16, true);
  writeTag(36, "data");
  output.setUint32(40, payloadLength, true);
  let outputOffset = 44;
  for (const piece of pieces) { result.set(piece, outputOffset); outputOffset += piece.length; }
  return result;
}

async function proxyHTTP(request: Request, env: Env, path: string, claims: AccessClaims, stub: DurableObjectStub<TrialUsageGateway>): Promise<Response> {
  if (path === "/v1/audio/transcriptions") {
    const contentLength = Number(request.headers.get("content-length") ?? 0);
    if (contentLength > MAX_AUDIO_BYTES) return jsonError("Audio request is too large.", 413);
    let form: FormData;
    try { form = await request.formData(); } catch { return jsonError("Invalid audio request.", 400); }
    const audio = form.get("file");
    if (!(audio instanceof File) || audio.size <= 0 || audio.size > MAX_AUDIO_BYTES) return jsonError("A valid audio file is required.", 400);
    const durationMs = validateWavDurationMs(await audio.arrayBuffer());
    if (!durationMs) return jsonError("Audio duration could not be verified.", 400);
    const operationID = request.headers.get("X-Usage-Operation-ID") ?? crypto.randomUUID();
    const audioSessionID = request.headers.get("X-Audio-Session-ID") ?? operationID;
    const startMsHeader = Number(request.headers.get("X-Audio-Start-MS") ?? 0);
    if (!Number.isSafeInteger(startMsHeader) || startMsHeader < 0) return jsonError("Invalid audio range.", 400);
    const operationKind = request.headers.get("X-Usage-Operation-Type") === "diarization" ? "diarization" : "transcription";
    const usageResponse = await stub.fetch("https://usage.internal/consume", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ operationID, audioSessionID, startMs: startMsHeader, durationMs, operationKind }),
    });
    if (usageResponse.status === 402) return withCors(usageResponse);
    if (usageResponse.status === 409) return withCors(usageResponse);
    if (!usageResponse.ok) return jsonError("Usage could not be recorded. Try again.", 503);
    const usage = await usageResponse.json() as UsageSnapshot;
    if (usage.cachedResponse) {
      return withCors(new Response(usage.cachedResponse.body, {
        status: usage.cachedResponse.status,
        headers: { "Content-Type": usage.cachedResponse.contentType },
      }));
    }
    if (usage.alreadyCounted) return jsonError("The previous result is unavailable; retry is blocked to prevent duplicate processing charges.", 409);
    if (usage.uncoveredRanges?.length && (usage.chargedMs ?? 0) < durationMs) {
      const cropped = cropWavToRanges(await audio.arrayBuffer(), usage.uncoveredRanges);
      if (cropped) form.set("file", new File([cropped], audio.name, { type: audio.type || "audio/wav" }));
    }
    const headers = new Headers(request.headers);
    headers.delete("content-type");
    headers.delete("content-length");
    request = new Request(request.url, { method: "POST", headers, body: form });
  }
  const headers = openAIHeaders(request, env.OPENAI_API_KEY);
  let upstream: Response;
  try {
    upstream = await fetch(`${openAIBase(env)}${path}`, { method: "POST", headers, body: request.body });
  } catch {
    return jsonError("The transcription result is being verified. Retry shortly.", 503);
  }
  if (path === "/v1/audio/transcriptions" && request.method === "POST") {
    const operationID = request.headers.get("X-Usage-Operation-ID");
    if (operationID) {
      if (upstream.status >= 200 && upstream.status < 300) {
        const responseBody = await upstream.clone().text();
        await stub.fetch("https://usage.internal/complete", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ operationID, status: upstream.status, contentType: upstream.headers.get("Content-Type") ?? "application/json", responseBody }),
        });
      } else if (upstream.status < 500) {
        await stub.fetch("https://usage.internal/release", {
          method: "POST", headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ operationID }),
        });
      }
    }
  }
  return withCors(upstream);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders() });
    const url = new URL(request.url);
    if (url.pathname === "/revenuecat/webhook") return handleRevenueCatWebhook(request, env);
    if (!env.OPENAI_API_KEY) return jsonError("Worker is not configured.", 503);
    if (url.pathname === "/usage/session" && request.method === "POST") return createUsageSession(request, env);
    if (url.pathname === "/usage/demo-session" && request.method === "POST") return createDemoSession(request, env);
    if (url.pathname === "/usage/state" && request.method === "GET") {
      const authorized = await authorizedUsage(request, env);
      if (authorized instanceof Response) return authorized;
      return withCors(await authorized.stub.fetch("https://usage.internal/state", { method: "GET" }));
    }
    const isWebSocket = request.headers.get("Upgrade")?.toLowerCase() === "websocket";
    if (isWebSocket && url.pathname === "/v1/realtime") {
      const authorized = await authorizedUsage(request, env);
      if (authorized instanceof Response) return authorized;
      return authorized.stub.fetch(request);
    }
    const upstreamPath = ALLOWED_HTTP_ROUTES.get(url.pathname);
    if (request.method !== "POST" || !upstreamPath) return jsonError("Route not found.", 404);
    const authorized = await authorizedUsage(request, env);
    if (authorized instanceof Response) return authorized;
    if (upstreamPath === "/v1/chat/completions") {
      if (authorized.claims.demo) {
        const length = Number(request.headers.get("content-length") ?? 0);
        if (length > 32_768) return jsonError("Demo request is too large.", 413);
        const response = await authorized.stub.fetch("https://usage.internal/demo-chat", { method: "POST" });
        if (!response.ok) return withCors(response);
      }
      const headers = openAIHeaders(request, env.OPENAI_API_KEY);
      return withCors(await fetch(`${openAIBase(env)}${upstreamPath}`, { method: "POST", headers, body: request.body }));
    }
    return proxyHTTP(request, env, upstreamPath, authorized.claims, authorized.stub);
  },
};
