# OpenAI server-side Worker migration runbook

Use this procedure whenever an iOS project currently sends an OpenAI API key directly from the app.

This runbook uses a basic Cloudflare Worker-only proxy. It hides the OpenAI key from the shipped app, but it does not provide strong proof that callers are genuine app installations. Add authentication, App Attest, or another abuse-control layer before broad public distribution.

## 1. Incident response first

1. Revoke the leaked OpenAI key in the OpenAI dashboard.
2. Create a replacement key.
3. Search the current repository and history for `sk-` patterns.
4. Remove the key from local plist files, environment files, build settings, and generated app bundles.
5. Set OpenAI project spending limits and usage alerts.

Never ask an AI agent to receive or print the replacement key.

## 2. Create the Worker

Create a separate `worker/` directory in the project:

```text
worker/
  src/index.ts
  package.json
  tsconfig.json
  wrangler.jsonc
```

Use a narrow allowlist of routes. Do not create a general-purpose URL proxy.

Typical routes:

- `POST /v1/audio/transcriptions`
- `POST /v1/chat/completions`
- `GET /v1/realtime` with a WebSocket upgrade

The Worker must:

- Store the key as a Cloudflare secret named `OPENAI_API_KEY`.
- Remove any client-supplied `Authorization` header.
- Add `Authorization: Bearer ${env.OPENAI_API_KEY}` upstream.
- Forward only the approved routes and methods.
- Limit request sizes and reject unsupported routes.
- Avoid logging request bodies, transcripts, audio, or secrets.
- Disable preview URLs unless they are intentionally needed.

## 3. Install and deploy

From the Worker directory:

```sh
npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY
npm run typecheck
npm run deploy
```

When Wrangler asks for the secret value, paste the replacement OpenAI key directly into that prompt. It should not be added to `wrangler.jsonc`, source code, Git, or the iOS project.

Record the deployed Worker URL, for example:

```text
https://<worker-name>.<account>.workers.dev
```

## 4. Migrate the iOS app

Find every direct OpenAI call, not only transcription:

- Audio transcription
- Diarization
- Realtime transcription WebSocket
- Summaries
- Translation
- Transcript questions/chat
- Keyword extraction
- Any future embeddings, moderation, or image calls

Replace direct OpenAI URLs with the Worker URL. Remove all client-side OpenAI bearer headers and all code that loads `OpenAIAPIKey` from a plist or environment file.

Keep one configuration seam, such as:

```swift
static let workerBaseURL = "https://<deployed-worker-url>"
```

The app should treat the Worker URL as public configuration. Only the OpenAI key is secret.

For realtime WebSockets, convert the Worker URL from `https` to `wss` and connect to the Worker’s `/v1/realtime` route. The Worker injects the upstream OpenAI authorization header.

## 5. Verify before claiming completion

Run all of these checks:

```sh
cd worker
npm run typecheck
npm run deploy
```

Check the deployed Worker with an intentionally invalid, non-generative request. A response such as `model parameter is required` with HTTP 400 confirms the request reached OpenAI without generating a model response:

```sh
curl -X POST \
  "https://<worker-url>/v1/chat/completions" \
  -H "Content-Type: application/json" \
  --data '{}'
```

Then build the iOS project:

```sh
xcodebuild \
  -project <Project>.xcodeproj \
  -scheme "<Scheme>" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/<project>-derived \
  -clonedSourcePackagesDirPath /private/tmp/<project>-source-packages \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Finally perform a real app-flow check for:

1. File transcription.
2. Diarization, if supported.
3. Realtime transcription.
4. Summary/translation/chat features.
5. Offline or Worker-unavailable fallback behavior.

Inspect the built app bundle and confirm no OpenAI key is present.

## 6. Documentation and handoff

Document:

- Worker name and public URL.
- Secret name, never the secret value.
- Supported routes.
- Deployment commands.
- iOS configuration location.
- Verification results and any remaining runtime limitations.
- The fact that hosting may be free while OpenAI usage remains billable.

Do not mark the migration complete from source checks alone. A successful build proves compilation, not that the deployed Worker, OpenAI authentication, WebSocket path, and real iOS user flow all work together.
