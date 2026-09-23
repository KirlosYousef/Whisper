# Whisper OpenAI Worker

This Worker is the only component that knows the OpenAI API key. The iOS app sends supported requests to this Worker, and the Worker forwards them to OpenAI after injecting its server-side secret.

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

The Worker intentionally does not provide a general-purpose OpenAI proxy. It strips any client-supplied `Authorization` header and only forwards the allowlisted routes.

## Cost and abuse note

Cloudflare Worker execution may remain within the free allowance, but OpenAI usage is still billable. Add OpenAI project spending limits and monitor Worker requests before distributing the app broadly. This basic version hides the OpenAI key; it does not prove that every caller is an unmodified copy of the iOS app.
