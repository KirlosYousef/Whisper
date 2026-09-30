# Whisper Worker

This Worker proxies the iOS app's allowlisted OpenAI requests and can receive RevenueCat subscription webhooks. It forwards only server-confirmed trial starts and trial conversions to the Revera EU Mixpanel project. Webhook processing is isolated from the OpenAI proxy configuration.

## Setup

From this directory:

```sh
npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY
npm run deploy
```

When prompted by `secret put`, paste the replacement OpenAI API key. Do not put it in this repository, `wrangler.jsonc`, or the iOS project.

The deploy command prints the Worker URL. Put that URL in `Whisper/Services/RealtimeTranscriptionService.swift` in `OpenAIConfiguration.workerBaseURL`, then build the iOS app.

## Exposed routes

- `POST /v1/audio/transcriptions`
- `POST /v1/chat/completions`
- `GET /v1/realtime` with a WebSocket upgrade
- `POST /revenuecat/webhook` for authenticated RevenueCat events

The Worker intentionally does not provide a general-purpose OpenAI proxy. It strips any client-supplied `Authorization` header and only forwards the allowlisted routes.

## RevenueCat trial attribution setup

The webhook route is implemented locally but is inactive until configured and deployed. It requires these Worker secrets/variables:

- Secret `REVENUECAT_WEBHOOK_AUTH_TOKEN`: a random high-entropy bearer token.
- Secret `MIXPANEL_PROJECT_TOKEN`: the Revera EU Mixpanel project token.
- Variable `REVENUECAT_APP_ID`: the Revera app ID shown in RevenueCat.

Set the two secrets with `npx wrangler secret put REVENUECAT_WEBHOOK_AUTH_TOKEN` and `npx wrangler secret put MIXPANEL_PROJECT_TOKEN`. Set `REVENUECAT_APP_ID` in the Worker environment configuration before deploying. In RevenueCat, add a webhook integration that points to `https://<deployed-worker-host>/revenuecat/webhook`, use the same `Bearer <token>` value as its Authorization header, scope it to the Revera app and production, and enable `INITIAL_PURCHASE` and `RENEWAL`.

The receiver emits `RevenueCat Trial Started` only for `INITIAL_PURCHASE` with `period_type=TRIAL`, and `RevenueCat Trial Converted` only for `RENEWAL` with `is_trial_conversion=true`. It forwards only the experiment ID/variant and the app's random Mixpanel distinct ID from RevenueCat subscriber attributes. It does not forward RevenueCat app user IDs, aliases, names, emails, product, price, or raw payloads. The app now writes `mixpanel_distinct_id` with its existing experiment attributes, so rebuild/release this app change before expecting attributed webhooks. Older customers or events without the required attributes are acknowledged but skipped.

Each forwarded event uses RevenueCat's stable webhook event ID as Mixpanel `$insert_id`, with the same event name, user ID, and timestamp on retries. This uses Mixpanel's documented event deduplication. Forwarding failures return a retryable 502 to RevenueCat; successful forwards require Mixpanel's verbose response to confirm acceptance. Mixpanel ingestion uses its EU endpoint and does not use the webhook sender's IP to identify users.

## Cost and abuse note

Cloudflare Worker execution may remain within the free allowance, but OpenAI usage is still billable. Add OpenAI project spending limits and monitor Worker requests before distributing the app broadly. The Worker hides the OpenAI key; it does not prove that every caller is an unmodified copy of the iOS app.

## Local verification

Run `npm run typecheck` and `npm test` from this directory. Tests use fixture payloads and a mocked Mixpanel endpoint; they do not send events or require secrets.
