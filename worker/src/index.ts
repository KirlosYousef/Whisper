import { handleRevenueCatWebhook } from "./revenuecat-webhook";

export interface Env {
  OPENAI_API_KEY: string;
  REVENUECAT_WEBHOOK_AUTH_TOKEN?: string;
  REVENUECAT_APP_ID?: string;
  MIXPANEL_PROJECT_TOKEN?: string;
}

const OPENAI_API = "https://api.openai.com";
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const ALLOWED_HTTP_ROUTES = new Map([
  ["/v1/audio/transcriptions", "/v1/audio/transcriptions"],
  ["/v1/chat/completions", "/v1/chat/completions"],
]);

function corsHeaders(): Headers {
  return new Headers({
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
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
  headers.set("Authorization", `Bearer ${apiKey}`);
  return headers;
}

async function proxyHTTP(request: Request, env: Env, path: string): Promise<Response> {
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (path === "/v1/audio/transcriptions" && contentLength > MAX_AUDIO_BYTES) {
    return jsonError("Audio request is too large.", 413);
  }

  const upstream = await fetch(`${OPENAI_API}${path}`, {
    method: "POST",
    headers: openAIHeaders(request, env.OPENAI_API_KEY),
    body: request.body,
  });
  return withCors(upstream);
}

async function proxyRealtime(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const upstream = new URL(`${OPENAI_API}/v1/realtime`);
  upstream.search = url.search;

  return fetch(new Request(upstream, {
    method: "GET",
    headers: openAIHeaders(request, env.OPENAI_API_KEY),
  }));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders() });

    const url = new URL(request.url);
    if (url.pathname === "/revenuecat/webhook") {
      return handleRevenueCatWebhook(request, env);
    }

    const isWebSocket = request.headers.get("Upgrade")?.toLowerCase() === "websocket";

    if (isWebSocket && url.pathname === "/v1/realtime") {
      if (!env.OPENAI_API_KEY) return jsonError("Worker is not configured.", 500);
      return proxyRealtime(request, env);
    }

    const upstreamPath = ALLOWED_HTTP_ROUTES.get(url.pathname);
    if (request.method !== "POST" || !upstreamPath) {
      return jsonError("Route not found.", 404);
    }
    if (!env.OPENAI_API_KEY) return jsonError("Worker is not configured.", 500);

    return proxyHTTP(request, env, upstreamPath);
  },
};
