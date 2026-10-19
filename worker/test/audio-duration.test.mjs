import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Buffer } from "node:buffer";
import { audioDurationMs, MAX_MP4_BYTES_PER_MS, mp4AudioDurationMs, wavDurationMs } from "../src/audio-duration.ts";

const u32 = (...values) => {
  const buffer = Buffer.alloc(values.length * 4);
  values.forEach((value, index) => buffer.writeUInt32BE(value, index * 4));
  return buffer;
};
const box = (type, ...parts) => {
  const body = Buffer.concat(parts.map(part => Buffer.isBuffer(part) ? part : Buffer.from(part)));
  return Buffer.concat([u32(8 + body.length), Buffer.from(type, "latin1"), body]);
};
const fullBox = (version, ...parts) => Buffer.concat([u32(version << 24), ...parts.map(part => Buffer.isBuffer(part) ? part : Buffer.from(part))]);
const ftyp = () => box("ftyp", "M4A ", u32(0), "M4A mp42isom");
const mdhd = (timescale, version = 0) => version === 1
  ? box("mdhd", fullBox(1), Buffer.alloc(16), u32(timescale), Buffer.alloc(8))
  : box("mdhd", fullBox(0), u32(0, 0, timescale, 0), Buffer.alloc(4));
const hdlr = type => box("hdlr", fullBox(0), u32(0), Buffer.from(type, "latin1"), Buffer.alloc(12), "x\0");
const stts = entries => box("stts", fullBox(0), u32(entries.length), ...entries.map(([count, delta]) => u32(count, delta)));
const stsz = count => box("stsz", fullBox(0), u32(0, count));
const audioTrak = ({ timescale = 16_000, entries = [[1000, 1024]], sampleCount = entries.reduce((sum, [count]) => sum + count, 0), version = 0, handler = "soun", edts = undefined } = {}) =>
  box("trak", edts ?? Buffer.alloc(0), box("mdia", mdhd(timescale, version), hdlr(handler), box("minf", box("stbl", stts(entries), stsz(sampleCount)))));
const moov = (...traks) => box("moov", ...traks);
const mdat = bytes => box("mdat", Buffer.alloc(bytes));
const m4a = (...boxes) => Buffer.concat([ftyp(), ...boxes]);
const toArrayBuffer = buffer => buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
const wavOf = (durationMs, sampleRate = 16_000) => {
  const data = Math.round(sampleRate * durationMs / 1000) * 2;
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
};

test("a single audio track reports its stts duration", () => {
  const bytes = m4a(moov(audioTrak()), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 64_000);
});

test("version 1 mdhd reads the timescale at its own offset", () => {
  const bytes = m4a(moov(audioTrak({ version: 1 })), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 64_000);
});

test("multiple stts entries are summed", () => {
  const bytes = m4a(moov(audioTrak({ entries: [[500, 1024], [500, 512]] })), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 48_000);
});

test("duration rounds up to whole milliseconds", () => {
  const bytes = m4a(moov(audioTrak({ timescale: 3, entries: [[1, 1]] })), mdat(100));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 334);
});

test("the longest audio track wins and video tracks are ignored", () => {
  const bytes = m4a(moov(
    audioTrak({ entries: [[1000, 1024]] }),
    audioTrak({ entries: [[2000, 1024]], sampleCount: 2000 }),
    audioTrak({ handler: "vide", entries: [[9_999_999, 1024]], sampleCount: 9_999_999 }),
  ), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 128_000);
});

test("a file with only a video track is rejected", () => {
  const bytes = m4a(moov(audioTrak({ handler: "vide" })), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), undefined);
});

test("zero timescale and zero duration are rejected", () => {
  assert.equal(mp4AudioDurationMs(toArrayBuffer(m4a(moov(audioTrak({ timescale: 0 })), mdat(2000)))), undefined);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(m4a(moov(audioTrak({ entries: [[0, 1024]], sampleCount: 0 })), mdat(2000)))), undefined);
});

test("a fragmented MP4 is rejected", () => {
  const bytes = m4a(moov(audioTrak()), box("moof", Buffer.alloc(16)), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), undefined);
});

test("a truncated box is rejected", () => {
  const bytes = m4a(moov(audioTrak()), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes.subarray(0, bytes.length - 5))), undefined);
});

test("a box size smaller than its header is rejected", () => {
  const bytes = Buffer.concat([ftyp(), u32(4), Buffer.from("free", "latin1"), Buffer.alloc(8)]);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), undefined);
});

test("64-bit largesize boxes are parsed", () => {
  const largeMdat = Buffer.concat([u32(1), Buffer.from("mdat", "latin1"), u32(0, 16 + 2000), Buffer.alloc(2000)]);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(m4a(moov(audioTrak()), largeMdat))), 64_000);
});

test("a stts/stsz sample count mismatch is rejected", () => {
  const bytes = m4a(moov(audioTrak({ entries: [[1000, 1024]], sampleCount: 999 })), mdat(2000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), undefined);
});

test("an underreported duration is rejected by the bytes-per-millisecond cap", () => {
  const bytes = m4a(moov(audioTrak({ entries: [[1, 1600]], sampleCount: 1 })), mdat(200_000));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), undefined);
  assert.equal(audioDurationMs(toArrayBuffer(bytes)), undefined);
});

test("the bytes-per-millisecond cap is inclusive at exactly MAX_MP4_BYTES_PER_MS", () => {
  assert.equal(MAX_MP4_BYTES_PER_MS, 32);
  // 1000 samples at 16/16000 s is exactly 1000 ms, so 32 bytes per ms means 32000 bytes in total.
  const file = payload => m4a(moov(audioTrak({ entries: [[1000, 16]], sampleCount: 1000 })), mdat(payload));
  const payload = 32_000 - file(0).length;
  assert.equal(file(payload).length, 32_000);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(file(payload))), 1000);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(file(payload + 1))), undefined);
});

test("garbage input is rejected without throwing", () => {
  assert.equal(mp4AudioDurationMs(new ArrayBuffer(0)), undefined);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(Buffer.from("not an mp4 file at all, just text"))), undefined);
  assert.equal(audioDurationMs(toArrayBuffer(Buffer.from("garbage bytes"))), undefined);
  assert.equal(audioDurationMs(new ArrayBuffer(3)), undefined);
  assert.equal(audioDurationMs(new ArrayBuffer(0)), undefined);
  // Every corrupted prefix of a valid file must fail cleanly rather than throw.
  const valid = m4a(moov(audioTrak()), mdat(2000));
  for (let length = 0; length < valid.length; length++) {
    assert.doesNotThrow(() => audioDurationMs(toArrayBuffer(valid.subarray(0, length))));
  }
});

test("audioDurationMs dispatches MP4 and WAV by signature", () => {
  assert.equal(audioDurationMs(toArrayBuffer(m4a(moov(audioTrak()), mdat(2000)))), 64_000);
  assert.equal(audioDurationMs(toArrayBuffer(wavOf(2000))), 2000);
});

test("WAV still parses through wavDurationMs and audioDurationMs", () => {
  assert.equal(wavDurationMs(toArrayBuffer(wavOf(2000))), 2000);
  assert.equal(audioDurationMs(toArrayBuffer(wavOf(1234))), 1234);
});

// An iTunSMPB tag as written by AAC encoders, inside moov/udta/meta/ilst/----.
const iTunSMPB = (priming, remainder, valid) => {
  const hex = (value, width) => value.toString(16).toUpperCase().padStart(width, "0");
  const text = ` 00000000 ${hex(priming, 8)} ${hex(remainder, 8)} ${hex(valid, 16)} 00000000`;
  return box("udta", box("meta", fullBox(0), box("ilst", box("----",
    box("mean", fullBox(0), "com.apple.iTunes"),
    box("name", fullBox(0), "iTunSMPB"),
    box("data", u32(1, 0), text)))));
};
// Stts totals 84992 frames at 16 kHz (83 samples of 1024).
const mvhd = (timescale) => box("mvhd", fullBox(0), u32(0, 0, timescale, 0), Buffer.alloc(80));
const tagged = (tag, extra = {}) => m4a(moov(mvhd(16_000), audioTrak({ entries: [[83, 1024]], ...extra }), tag), mdat(2000));

test("an iTunSMPB tag trims priming and remainder frames", () => {
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(iTunSMPB(2112, 533, 82347)))), 5147);
});

test("an iTunSMPB tag claiming a deduction above the bound is ignored", () => {
  // Priming and remainder total 5112 frames, which is above min(4096, 10%) of 84992.
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(iTunSMPB(2112, 3000, 79880)))), 5312);
});

test("a malformed iTunSMPB tag is ignored", () => {
  const malformedTag = box("udta", box("meta", fullBox(0), box("ilst", box("----",
    box("name", fullBox(0), "iTunSMPB"),
    box("data", u32(1, 0), " 00000000 0000ZZZZ 00000215 00000000000141AB")))));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(malformedTag))), 5312);
  const truncatedTag = box("udta", box("meta", fullBox(0), box("ilst", Buffer.alloc(5))));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(truncatedTag))), 5312);
});

test("an iTunSMPB tag whose frames do not add up to the stts total is ignored", () => {
  // The tag sums to 82347 frames, 2645 short of the 84992-frame stts total, so it is not trusted.
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(iTunSMPB(0, 0, 82347)))), 5312);
});

test("a single non-empty edit list entry trims playback to its segment", () => {
  const edts = box("edts", box("elst", fullBox(0), u32(1), u32(82347, 2112, 0x00010000)));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(Buffer.alloc(0), { edts }))), 5147);
});

test("an edit list with more than one entry is ignored", () => {
  const edts = box("edts", box("elst", fullBox(0), u32(2), u32(40000, 2112, 0x00010000), u32(42347, 0, 0x00010000)));
  assert.equal(mp4AudioDurationMs(toArrayBuffer(tagged(Buffer.alloc(0), { edts }))), 5312);
});

test("a real AAC M4A produced by afconvert reports its afinfo duration", () => {
  // Fixture: `say` (16 kHz LEI16) -> `afconvert -f m4af -d aac -c 1 -b 32000`.
  // afinfo: "estimated duration: 5.146687 sec", "82347 valid frames + 2112 priming + 533 remainder = 84992".
  // The file carries an iTunSMPB tag, so the valid frame count (82347 at 16 kHz) is used: ceil(82347 * 1000 / 16000) = 5147 ms.
  const bytes = readFileSync(new URL("./fixtures/speech.m4a", import.meta.url));
  assert.ok(bytes.length < 100 * 1024);
  assert.equal(mp4AudioDurationMs(toArrayBuffer(bytes)), 5147);
  assert.equal(audioDurationMs(toArrayBuffer(bytes)), 5147);
  assert.ok(Math.abs(5147 - 5146.687) <= 50);
});
