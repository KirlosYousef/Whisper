const MIXPANEL_TRACK_URL = "https://api-eu.mixpanel.com/track?ip=0&verbose=1";
const EXPECTED_EXPERIMENT_ID = "onboarding_realtime_demo_v1";
const ALLOWED_VARIANTS = new Set(["control", "realtime_demo"]);
const MAX_WEBHOOK_BYTES = 64 * 1024;

export interface RevenueCatWebhookEnv {
  REVENUECAT_WEBHOOK_AUTH_TOKEN?: string;
  REVENUECAT_APP_ID?: string;
  MIXPANEL_PROJECT_TOKEN?: string;
}

interface RevenueCatAttribute {
  value?: unknown;
}

interface RevenueCatEvent {
  id?: unknown;
  app_id?: unknown;
  type?: unknown;
  period_type?: unknown;
  is_trial_conversion?: unknown;
  event_timestamp_ms?: unknown;
  subscriber_attributes?: Record<string, RevenueCatAttribute>;
}

interface RevenueCatPayload {
  event?: RevenueCatEvent;
}

interface MixpanelEvent {
  event: "RevenueCat Trial Started" | "RevenueCat Trial Converted";
  properties: Record<string, string | number | boolean>;
}

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let difference = a.length ^ b.length;
  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return difference === 0;
}

function attributeValue(attributes: RevenueCatEvent["subscriber_attributes"], key: string): string | undefined {
  const value = attributes?.[key]?.value;
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function trialEventKind(event: RevenueCatEvent): MixpanelEvent["event"] | undefined {
  if (event.type === "INITIAL_PURCHASE" && event.period_type === "TRIAL") {
    return "RevenueCat Trial Started";
  }
  if (event.type === "RENEWAL" && event.is_trial_conversion === true) {
    return "RevenueCat Trial Converted";
  }
  return undefined;
}

export function buildMixpanelTrialEvent(
  event: RevenueCatEvent,
  mixpanelToken: string
): MixpanelEvent | undefined {
  const eventName = trialEventKind(event);
  if (!eventName) return undefined;

  const eventID = typeof event.id === "string" && event.id.length > 0 ? event.id : undefined;
  const timestamp = typeof event.event_timestamp_ms === "number" ? event.event_timestamp_ms : undefined;
  const experimentID = attributeValue(event.subscriber_attributes, "experiment_id");
  const variant = attributeValue(event.subscriber_attributes, "experiment_variant");
  const distinctID = attributeValue(event.subscriber_attributes, "mixpanel_distinct_id");

  // Avoid associating PII with Mixpanel and only accept the experiment this pilot measures.
  if (!eventID || !timestamp || !experimentID || !variant || !distinctID) return undefined;
  if (experimentID !== EXPECTED_EXPERIMENT_ID || !ALLOWED_VARIANTS.has(variant)) return undefined;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(distinctID)) {
    return undefined;
  }

  const properties: Record<string, string | number | boolean> = {
    token: mixpanelToken,
    distinct_id: distinctID,
    time: Math.floor(timestamp / 1000),
    "$insert_id": eventID,
    experiment_id: experimentID,
    experiment_variant: variant,
    attribution_source: "revenuecat_webhook",
    revenuecat_event_type: String(event.type),
  };

  return { event: eventName, properties };
}

export async function handleRevenueCatWebhook(
  request: Request,
  env: RevenueCatWebhookEnv,
  fetcher: typeof fetch = fetch
): Promise<Response> {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!env.REVENUECAT_WEBHOOK_AUTH_TOKEN || !env.REVENUECAT_APP_ID || !env.MIXPANEL_PROJECT_TOKEN) {
    return new Response("Webhook integration is not configured", { status: 503 });
  }

  const authorization = request.headers.get("Authorization") ?? "";
  if (!constantTimeEqual(authorization, `Bearer ${env.REVENUECAT_WEBHOOK_AUTH_TOKEN}`)) {
    return new Response("Unauthorized", { status: 401 });
  }

  const contentLength = Number(request.headers.get("Content-Length") ?? 0);
  if (contentLength > MAX_WEBHOOK_BYTES) return new Response("Payload too large", { status: 413 });

  let payload: unknown;
  try {
    const body = await request.text();
    if (new TextEncoder().encode(body).length > MAX_WEBHOOK_BYTES) {
      return new Response("Payload too large", { status: 413 });
    }
    payload = JSON.parse(body) as unknown;
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  if (!payload || typeof payload !== "object") return new Response("Invalid webhook payload", { status: 400 });
  const event = (payload as RevenueCatPayload).event;
  if (!event || typeof event !== "object" || event.app_id !== env.REVENUECAT_APP_ID) {
    return new Response("Invalid webhook app", { status: 400 });
  }

  const mixpanelEvent = buildMixpanelTrialEvent(event, env.MIXPANEL_PROJECT_TOKEN);
  if (!mixpanelEvent) {
    // Non-trial events and events that predate attribution are acknowledged, never retried.
    return Response.json({ received: true, forwarded: false });
  }

  let response: Response;
  try {
    response = await fetcher(MIXPANEL_TRACK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify([mixpanelEvent]),
    });
  } catch {
    return new Response("Analytics forwarding failed", { status: 502 });
  }

  if (!response.ok) return new Response("Analytics forwarding failed", { status: 502 });
  try {
    const result = await response.json() as { status?: unknown };
    if (result.status !== 1) return new Response("Analytics rejected event", { status: 502 });
  } catch {
    return new Response("Invalid analytics response", { status: 502 });
  }

  return Response.json({ received: true, forwarded: true });
}
