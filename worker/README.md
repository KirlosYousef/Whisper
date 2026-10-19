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
- `POST /usage/session` and `GET /usage/state` for verified subscriber access and usage
- `POST /usage/demo-session` for the restricted onboarding preview
- `POST /revenuecat/webhook` for authenticated RevenueCat events

The Worker intentionally does not provide a general-purpose OpenAI proxy. It strips any client-supplied `Authorization` header and only forwards the allowlisted routes.

## Trial usage enforcement

Cloudflare SQLite Durable Objects keep one usage ledger per verified Apple original transaction ID. The trial allowance is 1,800 seconds total; currently paid subscriptions have no cap. The onboarding preview has a separate 15-second limit. File duration is measured from validated PCM WAV or AAC/M4A data, and live audio is metered as it passes through the Worker.

Before issuing an access token, the Worker validates the StoreKit transaction JWS with Apple's App Store Server Library and checks the matching active `WhisperNote Pro` entitlement and store transaction through RevenueCat's subscriber API. The RevenueCat app-user ID is only a lookup key; it cannot grant access without the matching signed Apple transaction.

Access enforcement requires two additional Worker secrets:

- `USAGE_SESSION_SECRET`: a random high-entropy signing key for short-lived Worker access tokens.
- `REVENUECAT_SECRET_API_KEY`: a RevenueCat secret API key, stored only in Cloudflare, for read-only subscriber verification.

Set them with `npx wrangler secret put USAGE_SESSION_SECRET` and `npx wrangler secret put REVENUECAT_SECRET_API_KEY`. Never add their values to this repository or paste them into chat. Do not activate this Worker before the updated iOS app is ready; older app versions must update before cloud transcription can continue.

### Access rules

- **Trial**: `AnnualThreeDayTrial` during its 3-day free introductory offer. 30 transcription minutes in total, counted by the Worker per original transaction ID. The trial's last request may run up to 30 seconds past the allowance; it is charged only what was left, so the trial ends at exactly 0. Live streams forward the last of the allowance and then close with `4409`.
- **Unlimited**: `AnnualUnlimited`, or `AnnualThreeDayTrial` after Apple renews it into its paid year when the 3 days end. No cap.
- **No access**: expired, refunded or upgraded-away transactions. An upgraded transaction (`isUpgraded`) can never pull a user back to the trial tier.

The iOS app reads these states from `/usage/session` and `/usage/state`: no subscription shows the hard paywall; used-up trial minutes show the Unlimited offer, which the user can close to read existing transcripts; recording asks for the upgrade before any microphone prompt or connection.

### App Store Connect: make “Upgrade to Unlimited” take effect immediately

Both products must be in the same subscription group, with **`AnnualUnlimited` ranked above `AnnualThreeDayTrial`** (a higher service level). The App Store then treats buying Unlimited during the trial as an upgrade: it starts at once, the trial transaction is marked upgraded, and the Worker moves the same ledger to unlimited on the next session. If Unlimited is ranked below the trial plan, the App Store schedules it for when the trial ends; the app then shows “Unlimited starts <date>” instead of unlocking, which is the behaviour users report as “I upgraded but nothing changed”.

Before public release, verify on a physical iPhone in sandbox that buying Unlimited after the 30 minutes are used unlocks recording within a few seconds, billing starts immediately, renewal is correct, and the original trial does not cause an extra charge.

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
