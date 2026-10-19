import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { Buffer } from "node:buffer";
import test, { before, after } from "node:test";
import WebSocket from "ws";
import { demoToken, startMockOpenAI, startWorker } from "./support/harness.mjs";

const TIMEOUT = { timeout: 60_000 };
let mock;
let worker;

async function waitFor(predicate, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

function connect(token, { audioSessionID = "session-under-test", startMs = "0" } = {}) {
  const url = `${worker.url.replace("http", "ws")}/v1/realtime?intent=transcription`;
  const socket = new WebSocket(url, {
    headers: { Authorization: `Bearer ${token}`, "X-Audio-Session-ID": audioSessionID, "X-Audio-Start-MS": startMs },
  });
  const inbox = [];
  socket.on("message", data => inbox.push(data.toString()));
  return { socket, inbox };
}

function open(socket) {
  return new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", reject);
  });
}

function closed(socket) {
  return new Promise(resolve => socket.once("close", (code, reason) => resolve({ code, reason: reason.toString() })));
}

function upstreamRecord() {
  return mock.realtimeSockets.at(-1);
}

function appends(record) {
  return record.messages
    .filter(message => typeof message === "string")
    .map(message => JSON.parse(message))
    .filter(message => message.type === "input_audio_buffer.append");
}

before(async () => {
  mock = await startMockOpenAI();
  worker = await startWorker({ openAIBase: mock.url });
}, TIMEOUT);

after(async () => {
  await worker?.stop();
  await mock?.stop();
});

test("upgrade succeeds with the server's API key and no client credentials upstream", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const { socket } = connect(token, { audioSessionID: "auth-check", startMs: "0" });
  await open(socket);
  await waitFor(() => mock.realtimeSockets.length > 0);

  const upgrade = mock.requests.findLast(request => request.upgrade);
  assert.equal(upgrade.headers.authorization, "Bearer test-openai-key");
  assert.match(upgrade.url, /intent=transcription/);
  assert.equal(upgrade.headers["x-audio-session-id"], undefined);
  assert.equal(upgrade.headers["x-audio-start-ms"], undefined);
  assert.notEqual(upgrade.headers.authorization, `Bearer ${token}`);
  socket.close();
  await closed(socket);
});

test("messages flow both ways unchanged", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const { socket, inbox } = connect(token, { audioSessionID: "passthrough" });
  await open(socket);
  await waitFor(() => mock.realtimeSockets.length > 0);
  const record = upstreamRecord();

  record.socket.send(JSON.stringify({ type: "session.updated" }));
  await waitFor(() => inbox.some(message => message === JSON.stringify({ type: "session.updated" })));

  const update = JSON.stringify({ type: "session.update", session: { modalities: ["text"] } });
  socket.send(update);
  await waitFor(() => record.messages.includes(update));
  socket.close();
  await closed(socket);
});

test("append audio is forwarded as standard base64 without audio_start_ms", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const { socket } = connect(token, { audioSessionID: "encoding" });
  await open(socket);
  await waitFor(() => mock.realtimeSockets.length > 0);
  const record = upstreamRecord();

  const bytes = new Uint8Array(randomBytes(9600));
  socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio: Buffer.from(bytes).toString("base64"), audio_start_ms: 0 }));
  await waitFor(() => appends(record).length === 1);

  const [forwarded] = appends(record);
  assert.equal(forwarded.audio, Buffer.from(bytes).toString("base64"));
  assert.equal("audio_start_ms" in forwarded, false);
  socket.close();
  await closed(socket);
});

test("re-sent audio is not forwarded again, and the next chunk is", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const { socket } = connect(token, { audioSessionID: "dedupe" });
  await open(socket);
  await waitFor(() => mock.realtimeSockets.length > 0);
  const record = upstreamRecord();

  const first = Buffer.from(randomBytes(9600)).toString("base64");
  const second = Buffer.from(randomBytes(9600)).toString("base64");
  socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio: first, audio_start_ms: 0 }));
  await waitFor(() => appends(record).length === 1);
  socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio: first, audio_start_ms: 0 }));
  socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio: second, audio_start_ms: 200 }));
  await waitFor(() => appends(record).length === 2);

  const forwarded = appends(record);
  assert.equal(forwarded[0].audio, first);
  assert.equal(forwarded[1].audio, second);
  socket.close();
  await closed(socket);
});

test("streaming past the demo allowance closes with TRIAL_USAGE_EXHAUSTED", TIMEOUT, async () => {
  const token = await demoToken(worker.url);
  const { socket } = connect(token, { audioSessionID: "exhaust" });
  const closing = closed(socket);
  await open(socket);

  const audio = Buffer.from(randomBytes(9600)).toString("base64");
  for (let index = 0; index < 80 && socket.readyState === WebSocket.OPEN; index += 1) {
    socket.send(JSON.stringify({ type: "input_audio_buffer.append", audio, audio_start_ms: index * 200 }));
  }
  const result = await closing;
  assert.equal(result.code, 4409);
  assert.equal(result.reason, "TRIAL_USAGE_EXHAUSTED");
});

test("a rejected upstream upgrade surfaces as HTTP 502", TIMEOUT, async () => {
  mock.setRejectRealtime(true);
  try {
    const token = await demoToken(worker.url);
    const { socket } = connect(token, { audioSessionID: "rejected" });
    const status = await new Promise((resolve, reject) => {
      socket.once("unexpected-response", (_request, response) => resolve(response.statusCode));
      socket.once("open", () => reject(new Error("upgrade unexpectedly succeeded")));
      socket.once("error", () => {});
    });
    assert.equal(status, 502);
  } finally {
    mock.setRejectRealtime(false);
  }
});
