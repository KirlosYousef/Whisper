import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { demoToken, startMockOpenAI, startWorker, wav } from "./support/harness.mjs";

const TIMEOUT = { timeout: 60_000 };
let mock;
let worker;
const replies = [];

before(async () => {
  mock = await startMockOpenAI({ onHTTP: async () => replies.shift() ?? { status: 200, json: { text: "transcript" } } });
  worker = await startWorker({ openAIBase: mock.url });
}, TIMEOUT);

after(async () => {
  await worker?.stop();
  await mock?.stop();
});

/** A WAV with a WAVE_FORMAT_EXTENSIBLE fmt chunk (40 bytes) whose SubFormat is PCM. */
function extensibleWav(durationMs, sampleRate = 16_000) {
  const data = Math.round(sampleRate * durationMs / 1_000) * 2;
  const buffer = Buffer.alloc(68 + data);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(buffer.length - 8, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(40, 16);
  buffer.writeUInt16LE(0xfffe, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.writeUInt16LE(22, 36);
  buffer.writeUInt16LE(16, 38);
  buffer.writeUInt32LE(4, 40);
  Buffer.from("0100000000001000800000aa00389b71", "hex").copy(buffer, 44);
  buffer.write("data", 60);
  buffer.writeUInt32LE(data, 64);
  return buffer;
}

async function transcribe(token, {
  operationID = randomUUID(),
  sessionID = randomUUID(),
  startMs = 0,
  bytes = wav(2000),
  kind = "transcription",
  authorization = `Bearer ${token}`,
} = {}) {
  const form = new FormData();
  form.set("file", new Blob([bytes], { type: "audio/wav" }), "a.wav");
  form.set("model", "x");
  return fetch(`${worker.url}/v1/audio/transcriptions`, {
    method: "POST",
    headers: {
      Authorization: authorization,
      "X-Usage-Operation-ID": operationID,
      "X-Usage-Operation-Type": kind,
      "X-Audio-Session-ID": sessionID,
      "X-Audio-Start-MS": String(startMs),
    },
    body: form,
  });
}

async function usageState(token) {
  const response = await fetch(`${worker.url}/usage/state`, { headers: { Authorization: `Bearer ${token}` } });
  assert.equal(response.status, 200);
  return response.json();
}

test("diarization after transcribed segments forwards the full recording and charges nothing extra", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const sessionID = randomUUID();
  assert.equal((await transcribe(token, { sessionID, startMs: 0 })).status, 200);
  assert.equal((await transcribe(token, { sessionID, startMs: 2000 })).status, 200);

  const full = wav(4000);
  const requestsBefore = mock.requests.length;
  const response = await transcribe(token, { sessionID, startMs: 0, bytes: full, kind: "diarization" });
  assert.equal(response.status, 200);
  assert.equal(mock.requests.length, requestsBefore + 1);
  const forwarded = mock.requests.at(-1).body;
  assert.ok(forwarded.length >= full.length, "forwarded multipart body is smaller than the full recording");
  assert.ok(forwarded.includes(full), "forwarded body does not contain the full WAV bytes");
  assert.equal((await usageState(token)).consumedMs, 4000);
});

test("diarization of a partly transcribed recording forwards the full recording and charges only the uncovered part", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const sessionID = randomUUID();
  assert.equal((await transcribe(token, { sessionID, startMs: 0 })).status, 200);

  const full = wav(4000);
  const response = await transcribe(token, { sessionID, startMs: 0, bytes: full, kind: "diarization" });
  assert.equal(response.status, 200);
  assert.ok(mock.requests.at(-1).body.includes(full), "partially covered diarization was cropped before forwarding");
  assert.equal((await usageState(token)).consumedMs, 4000);
});

test("upstream 500 then a retry with the same operation ID succeeds and is charged once", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const operationID = randomUUID();
  const sessionID = randomUUID();
  replies.push({ status: 500, json: { error: "boom" } });
  assert.equal((await transcribe(token, { operationID, sessionID })).status, 500);

  const retry = await transcribe(token, { operationID, sessionID });
  assert.equal(retry.status, 200);
  assert.equal((await usageState(token)).consumedMs, 2000);
});

test("upstream 500 releases the reservation without charging", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  replies.push({ status: 500, json: { error: "boom" } });
  assert.equal((await transcribe(token)).status, 500);

  const state = await usageState(token);
  assert.equal(state.consumedMs, 0);
  assert.equal(state.reservedMs, 0);
});

test("retrying an identical completed job under a new operation ID replays the cached transcript", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const sessionID = randomUUID();
  replies.push({ status: 200, json: { text: "first transcript" } });
  const first = await transcribe(token, { sessionID });
  assert.equal(first.status, 200);
  const firstBody = await first.text();

  const upstreamCallsBefore = mock.requests.length;
  const second = await transcribe(token, { sessionID });
  assert.equal(second.status, 200);
  assert.equal(await second.text(), firstBody);
  assert.equal(mock.requests.length, upstreamCallsBefore);
});

test("an overlapping but different job of the same kind returns duplicate_audio", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const sessionID = randomUUID();
  assert.equal((await transcribe(token, { sessionID, startMs: 0 })).status, 200);

  const overlapping = await transcribe(token, { sessionID, startMs: 1000 });
  assert.equal(overlapping.status, 409);
  const body = await overlapping.json();
  assert.equal(body.code, "duplicate_audio");
  assert.equal(typeof body.error, "string");
});

test("exceeding the demo allowance returns trial_exhausted", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const sessionID = randomUUID();
  assert.equal((await transcribe(token, { sessionID, startMs: 0, bytes: wav(10_000) })).status, 200);

  const exhausted = await transcribe(token, { sessionID, startMs: 10_000, bytes: wav(6_000) });
  assert.equal(exhausted.status, 402);
  const body = await exhausted.json();
  assert.equal(body.code, "trial_exhausted");
  assert.equal(body.error, "trial_exhausted");
});

test("an invalid bearer token returns session_expired", TIMEOUT, async () => {
  const response = await transcribe(null, { authorization: "Bearer not-a-valid-token" });
  assert.equal(response.status, 401);
  assert.equal((await response.json()).code, "session_expired");
});

test("a WAVE_FORMAT_EXTENSIBLE PCM recording is accepted", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const response = await transcribe(token, { bytes: extensibleWav(2000) });
  assert.equal(response.status, 200);
  assert.equal((await usageState(token)).consumedMs, 2000);
});
