// Local end-to-end harness: runs the Worker with `wrangler dev` against a mock OpenAI origin.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer } from "ws";

const workerRoot = fileURLToPath(new URL("../..", import.meta.url));

function listen(server) {
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));
}

/**
 * A stand-in for api.openai.com. `onHTTP(req, body)` returns `{ status, json }`; `onRealtime(socket, req)`
 * receives each upstream realtime socket. Every request is recorded in `requests`.
 */
export async function startMockOpenAI({ onHTTP, onRealtime } = {}) {
  const requests = [];
  const realtimeSockets = [];
  const control = { rejectRealtime: false };
  const server = createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    requests.push({ method: req.method, url: req.url, headers: req.headers, body });
    const reply = (await onHTTP?.(req, body)) ?? { status: 200, json: { text: "ok" } };
    res.writeHead(reply.status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(reply.json ?? {}));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    requests.push({ method: req.method, url: req.url, headers: req.headers, upgrade: true });
    if (control.rejectRealtime || req.headers.authorization !== "Bearer test-openai-key") {
      socket.end("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
      return;
    }
    wss.handleUpgrade(req, socket, head, ws => {
      const record = { socket: ws, request: req, messages: [] };
      ws.on("message", (data, isBinary) => record.messages.push(isBinary ? data : data.toString()));
      realtimeSockets.push(record);
      onRealtime?.(ws, req, record);
    });
  });
  const port = await listen(server);
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    realtimeSockets,
    /** When true, the mock answers every realtime upgrade with 401. */
    setRejectRealtime(value) { control.rejectRealtime = value; },
    async stop() {
      for (const client of wss.clients) client.terminate();
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
    },
  };
}

/** Starts the Worker locally with fresh Durable Object storage. */
export async function startWorker({ openAIBase, vars = {} }) {
  const persistDir = mkdtempSync(join(tmpdir(), "revera-worker-"));
  const portServer = createServer();
  const port = await listen(portServer);
  await new Promise(resolve => portServer.close(resolve));
  const allVars = {
    OPENAI_API_KEY: "test-openai-key",
    USAGE_SESSION_SECRET: `test-secret-${randomUUID()}`,
    OPENAI_API_BASE: openAIBase,
    ...vars,
  };
  const args = ["dev", "--ip", "127.0.0.1", "--port", String(port), "--persist-to", persistDir,
    "--show-interactive-dev-session=false", "--log-level", "warn"];
  for (const [key, value] of Object.entries(allVars)) args.push("--var", `${key}:${value}`);
  const logPath = join(persistDir, "wrangler.log");
  const logFD = openSync(logPath, "w");
  const child = spawn(join(workerRoot, "node_modules", ".bin", "wrangler"), args, {
    cwd: workerRoot,
    detached: true,
    stdio: ["ignore", logFD, logFD],
    env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
  });
  closeSync(logFD);
  const output = () => readFileSync(logPath, "utf8");
  // wrangler runs workerd as a child, so signal the whole process group.
  const killGroup = signal => { try { process.kill(-child.pid, signal); } catch { /* already gone */ } };
  const url = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 60_000;
  while (true) {
    if (child.exitCode != null) throw new Error(`wrangler dev exited early:\n${output()}`);
    try {
      const response = await fetch(`${url}/health-check-route`);
      await response.arrayBuffer();
      break;
    } catch {
      if (Date.now() > deadline) {
        killGroup("SIGKILL");
        throw new Error(`wrangler dev did not start:\n${output()}`);
      }
      await new Promise(resolve => setTimeout(resolve, 250));
    }
  }
  return {
    url,
    output,
    async stop() {
      const exited = new Promise(resolve => child.once("exit", resolve));
      killGroup("SIGTERM");
      await Promise.race([exited, new Promise(resolve => setTimeout(resolve, 5_000))]);
      killGroup("SIGKILL");
      child.unref();
      rmSync(persistDir, { recursive: true, force: true });
    },
  };
}

/** Creates an onboarding demo session (15-second allowance) and returns its bearer token. */
export async function demoToken(workerURL) {
  const response = await fetch(`${workerURL}/usage/demo-session`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ demoID: randomUUID() }),
  });
  if (!response.ok) throw new Error(`demo session failed: ${response.status} ${await response.text()}`);
  return (await response.json()).token;
}

/** A mono 16-bit PCM WAV of silence. */
export function wav(durationMs, sampleRate = 16_000) {
  const samples = Math.round(sampleRate * durationMs / 1_000);
  const data = samples * 2;
  const buffer = Buffer.alloc(44 + data);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + data, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write("data", 36);
  buffer.writeUInt32LE(data, 40);
  return buffer;
}
