import assert from "node:assert/strict";
import test from "node:test";
import { buildMixpanelTrialEvent, handleRevenueCatWebhook } from "../src/revenuecat-webhook.ts";

const env = {
  REVENUECAT_WEBHOOK_AUTH_TOKEN: "test-webhook-token",
  REVENUECAT_APP_ID: "revera-app-id",
  MIXPANEL_PROJECT_TOKEN: "mixpanel-test-token",
};

function fixture(overrides = {}) {
  return {
    id: "rc-event-123",
    app_id: env.REVENUECAT_APP_ID,
    type: "RENEWAL",
    period_type: "NORMAL",
    is_trial_conversion: true,
    event_timestamp_ms: 1_759_000_123_456,
    subscriber_attributes: {
      experiment_id: { value: "onboarding_realtime_demo_v1" },
      experiment_variant: { value: "realtime_demo" },
      mixpanel_distinct_id: { value: "8e3b0d28-a532-4f96-8f93-6c89a71598f2" },
      $email: { value: "must-not-forward@example.com" },
    },
    ...overrides,
  };
}

function request(payload, authorization = `Bearer ${env.REVENUECAT_WEBHOOK_AUTH_TOKEN}`) {
  return new Request("https://worker.example/revenuecat/webhook", {
    method: "POST",
    headers: { Authorization: authorization, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

test("builds a minimal attributed conversion and uses stable event fields for deduplication", () => {
  const event = buildMixpanelTrialEvent(fixture(), env.MIXPANEL_PROJECT_TOKEN);

  assert.equal(event.event, "RevenueCat Trial Converted");
  assert.deepEqual(event.properties, {
    token: env.MIXPANEL_PROJECT_TOKEN,
    distinct_id: "8e3b0d28-a532-4f96-8f93-6c89a71598f2",
    time: 1_759_000_123,
    $insert_id: "rc-event-123",
    experiment_id: "onboarding_realtime_demo_v1",
    experiment_variant: "realtime_demo",
    attribution_source: "revenuecat_webhook",
    revenuecat_event_type: "RENEWAL",
  });
});

test("recognizes only actual RevenueCat trial starts and trial-conversion renewals", () => {
  assert.equal(buildMixpanelTrialEvent(fixture({ type: "INITIAL_PURCHASE", period_type: "TRIAL" }), env.MIXPANEL_PROJECT_TOKEN).event,
    "RevenueCat Trial Started");
  assert.equal(buildMixpanelTrialEvent(fixture({ is_trial_conversion: false }), env.MIXPANEL_PROJECT_TOKEN), undefined);
  assert.equal(buildMixpanelTrialEvent(fixture({ type: "INITIAL_PURCHASE", period_type: "NORMAL" }), env.MIXPANEL_PROJECT_TOKEN), undefined);
});

test("skips events without experiment attribution or a pseudonymous Mixpanel ID", () => {
  assert.equal(buildMixpanelTrialEvent(fixture({ subscriber_attributes: {} }), env.MIXPANEL_PROJECT_TOKEN), undefined);
  assert.equal(buildMixpanelTrialEvent(fixture({
    subscriber_attributes: {
      experiment_id: { value: "onboarding_realtime_demo_v1" },
      experiment_variant: { value: "control" },
      mixpanel_distinct_id: { value: "person@example.com" },
    },
  }), env.MIXPANEL_PROJECT_TOKEN), undefined);
});

test("rejects unauthorized callers before reading or forwarding the payload", async () => {
  let forwarded = false;
  const response = await handleRevenueCatWebhook(request({ event: fixture() }, "Bearer wrong"), env, async () => {
    forwarded = true;
    return Response.json({ status: 1 });
  });

  assert.equal(response.status, 401);
  assert.equal(forwarded, false);
});

test("rejects webhooks for another RevenueCat app", async () => {
  const response = await handleRevenueCatWebhook(request({ event: fixture({ app_id: "other-app" }) }), env);
  assert.equal(response.status, 400);
});

test("rejects valid JSON that is not a webhook object", async () => {
  const response = await handleRevenueCatWebhook(request(null), env);
  assert.equal(response.status, 400);
});

test("acknowledges unrelated or pre-attribution events without forwarding", async () => {
  let forwarded = false;
  const response = await handleRevenueCatWebhook(request({ event: fixture({ type: "CANCELLATION" }) }), env, async () => {
    forwarded = true;
    return Response.json({ status: 1 });
  });

  assert.deepEqual(await response.json(), { received: true, forwarded: false });
  assert.equal(forwarded, false);
});

test("forwards to the EU Mixpanel endpoint and retries if Mixpanel does not accept the event", async () => {
  let captured;
  const response = await handleRevenueCatWebhook(request({ event: fixture() }), env, async (url, init) => {
    captured = { url, body: JSON.parse(init.body) };
    return Response.json({ status: 0, error: "rejected" });
  });

  assert.equal(captured.url, "https://api-eu.mixpanel.com/track?ip=0&verbose=1");
  assert.equal(captured.body[0].properties.experiment_variant, "realtime_demo");
  assert.equal("$email" in captured.body[0].properties, false);
  assert.equal(response.status, 502);
});

test("confirms delivery only after Mixpanel accepts the event", async () => {
  const response = await handleRevenueCatWebhook(request({ event: fixture() }), env, async () => Response.json({ status: 1 }));
  assert.deepEqual(await response.json(), { received: true, forwarded: true });
});
