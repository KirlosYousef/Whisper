export const PCM16_BYTES_PER_MS = 48;

export function decodeBase64(value: string): Uint8Array {
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/g, "");
  const binary = atob(normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "="));
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}

export function encodeBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

export function pcm16DurationMs(byteLength: number): number {
  return Math.ceil(byteLength / PCM16_BYTES_PER_MS);
}

export function sliceUncoveredAudio(bytes: Uint8Array, chunkStartMs: number, ranges: Array<{ startMs: number; endMs: number }>): Uint8Array[] {
  const clamp = (value: number) => Math.min(bytes.length, Math.max(0, value));
  const alignDown = (value: number) => value - (value % 2);
  const slices: Uint8Array[] = [];
  for (const range of ranges) {
    const start = alignDown(clamp((range.startMs - chunkStartMs) * PCM16_BYTES_PER_MS));
    const end = alignDown(clamp((range.endMs - chunkStartMs) * PCM16_BYTES_PER_MS));
    if (end > start) slices.push(bytes.subarray(start, end));
  }
  return slices;
}
