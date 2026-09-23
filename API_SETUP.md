# AI API setup

The OpenAI API key must not be placed in the iOS app or in `Whisper/Config.plist`. A shipped app can be inspected, even when the plist is ignored by Git.

## Deploy the Worker

From the repository root:

```sh
cd worker
npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY
npm run deploy
```

When `wrangler secret put OPENAI_API_KEY` prompts for a value, paste the replacement OpenAI API key there. The value is stored as a Cloudflare Worker secret and is not written into this repository.

The deploy output includes a URL similar to:

```text
https://whisper-openai-proxy.<account>.workers.dev
```

Copy that URL into `OpenAIConfiguration.workerBaseURL` in `Whisper/Services/RealtimeTranscriptionService.swift`. Do not paste the OpenAI key into the iOS project.

## Verify the setup

```sh
cd worker
npm run typecheck
npm run deploy
```

The iOS app uses the Worker for file transcription, diarization, summaries, translation, transcript chat, keyword extraction, and realtime transcription. The Worker only forwards supported endpoints and removes any client-supplied OpenAI authorization header before adding its own server-side secret.

## Security and cost

- Revoke the leaked OpenAI key before creating the replacement.
- Set an OpenAI project spending limit and usage alert.
- Do not commit `worker/.dev.vars` or any API key.
- This basic proxy hides the OpenAI key but does not provide strong app authentication. Add App Attest or user authentication before broad public distribution.
