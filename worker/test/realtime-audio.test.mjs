import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import test from "node:test";
import { Buffer } from "node:buffer";
import { decodeBase64, encodeBase64, pcm16DurationMs, sliceUncoveredAudio } from "../src/realtime-audio.ts";

test("standard base64 encoding matches Node, including padding and large buffers", () => {
  for (const size of [0, 1, 2, 3, 4, 47, 48, 9600, 0x8000 + 7, 200_000]) {
    const bytes = new Uint8Array(randomBytes(size));
    const encoded = encodeBase64(bytes);
    assert.equal(encoded, Buffer.from(bytes).toString("base64"), `size ${size}`);
    assert.deepEqual(decodeBase64(encoded), bytes, `round-trip size ${size}`);
  }
});

test("decodes URL-safe base64 with or without padding", () => {
  const bytes = Uint8Array.from([0xfb, 0xff, 0xbf]);
  assert.equal(Buffer.from(bytes).toString("base64"), "+/+/");
  assert.deepEqual(decodeBase64("-_-_"), bytes);

  const padded = Uint8Array.from([0xfb, 0xff]);
  assert.equal(Buffer.from(padded).toString("base64"), "+/8=");
  assert.deepEqual(decodeBase64("+/8="), padded);
  assert.deepEqual(decodeBase64("-_8="), padded);
  assert.deepEqual(decodeBase64("-_8"), padded);
});

test("pcm16DurationMs rounds up at 48 bytes per millisecond", () => {
  assert.equal(pcm16DurationMs(0), 0);
  assert.equal(pcm16DurationMs(1), 1);
  assert.equal(pcm16DurationMs(47), 1);
  assert.equal(pcm16DurationMs(48), 1);
  assert.equal(pcm16DurationMs(49), 2);
  assert.equal(pcm16DurationMs(9600), 200);
});

test("sliceUncoveredAudio returns the whole chunk when one range covers it", () => {
  const bytes = new Uint8Array(randomBytes(9600));
  const slices = sliceUncoveredAudio(bytes, 0, [{ startMs: 0, endMs: pcm16DurationMs(bytes.length) }]);
  assert.equal(slices.length, 1);
  assert.deepEqual(slices[0], bytes);
});

test("sliceUncoveredAudio slices a partial head overlap", () => {
  const bytes = new Uint8Array(randomBytes(9600));
  const slices = sliceUncoveredAudio(bytes, 100, [{ startMs: 100, endMs: 150 }]);
  assert.equal(slices.length, 1);
  assert.deepEqual(slices[0], bytes.subarray(0, 2400));
});

test("sliceUncoveredAudio returns one slice per range across a middle gap", () => {
  const bytes = new Uint8Array(randomBytes(9600));
  const slices = sliceUncoveredAudio(bytes, 0, [{ startMs: 0, endMs: 50 }, { startMs: 100, endMs: 150 }]);
  assert.equal(slices.length, 2);
  assert.deepEqual(slices[0], bytes.subarray(0, 2400));
  assert.deepEqual(slices[1], bytes.subarray(4800, 7200));
});

test("sliceUncoveredAudio keeps trailing samples of an odd-length chunk", () => {
  const bytes = new Uint8Array(randomBytes(49));
  const slices = sliceUncoveredAudio(bytes, 0, [{ startMs: 0, endMs: pcm16DurationMs(bytes.length) }]);
  assert.equal(slices.length, 1);
  assert.deepEqual(slices[0], bytes.subarray(0, 48));
});

test("sliceUncoveredAudio clamps ranges that extend beyond the chunk", () => {
  const bytes = new Uint8Array(randomBytes(9600));
  const slices = sliceUncoveredAudio(bytes, 0, [{ startMs: 150, endMs: 10_000 }]);
  assert.equal(slices.length, 1);
  assert.deepEqual(slices[0], bytes.subarray(7200, 9600));
});

test("sliceUncoveredAudio skips empty and out-of-chunk ranges", () => {
  const bytes = new Uint8Array(randomBytes(9600));
  assert.deepEqual(sliceUncoveredAudio(bytes, 0, []), []);
  assert.deepEqual(sliceUncoveredAudio(bytes, 0, [{ startMs: 50, endMs: 50 }]), []);
  assert.deepEqual(sliceUncoveredAudio(bytes, 500, [{ startMs: 0, endMs: 100 }]), []);
});
