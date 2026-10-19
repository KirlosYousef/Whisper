export const MAX_MP4_BYTES_PER_MS = 32;

type Box = { type: string; bodyStart: number; end: number };

class MalformedMP4 extends Error {}

function malformed(): never {
  throw new MalformedMP4();
}

function u8(view: DataView, offset: number, end: number): number {
  if (offset < 0 || offset + 1 > end) malformed();
  return view.getUint8(offset);
}

function u32(view: DataView, offset: number, end: number): number {
  if (offset < 0 || offset + 4 > end) malformed();
  return view.getUint32(offset, false);
}

function fourCC(view: DataView, offset: number, end: number): string {
  if (offset < 0 || offset + 4 > end) malformed();
  return String.fromCharCode(view.getUint8(offset), view.getUint8(offset + 1), view.getUint8(offset + 2), view.getUint8(offset + 3));
}

function boxes(view: DataView, start: number, end: number): Box[] {
  const result: Box[] = [];
  let offset = start;
  while (offset < end) {
    if (offset + 8 > end) malformed();
    let size = u32(view, offset, end);
    const type = fourCC(view, offset + 4, end);
    let header = 8;
    if (size === 1) {
      if (offset + 16 > end) malformed();
      const largesize = view.getBigUint64(offset + 8, false);
      if (largesize > BigInt(Number.MAX_SAFE_INTEGER)) malformed();
      size = Number(largesize);
      header = 16;
    } else if (size === 0) {
      size = end - offset;
    }
    if (size < header || offset + size > end) malformed();
    result.push({ type, bodyStart: offset + header, end: offset + size });
    offset += size;
  }
  return result;
}

function child(view: DataView, parent: Box, type: string): Box | undefined {
  return boxes(view, parent.bodyStart, parent.end).find(box => box.type === type);
}

export function wavDurationMs(data: ArrayBuffer): number | undefined {
  const view = new DataView(data);
  if (data.byteLength < 44 || view.getUint32(0, false) !== 0x52494646 || view.getUint32(8, false) !== 0x57415645) return undefined;
  let offset = 12;
  let sampleRate: number | undefined;
  let blockAlign: number | undefined;
  let byteRate: number | undefined;
  let encoding: number | undefined;
  let channels: number | undefined;
  let bitDepth: number | undefined;
  let dataBytes: number | undefined;
  while (offset + 8 <= data.byteLength) {
    const id = view.getUint32(offset, false);
    const size = view.getUint32(offset + 4, true);
    const bodyOffset = offset + 8;
    if (bodyOffset + size > data.byteLength) return undefined;
    if (id === 0x666d7420 && size >= 16) {
      encoding = view.getUint16(bodyOffset, true);
      // WAVE_FORMAT_EXTENSIBLE: the real format is the SubFormat GUID's leading uint16 at fmt body offset 24.
      if (encoding === 0xfffe && size >= 40) encoding = view.getUint16(bodyOffset + 24, true);
      channels = view.getUint16(bodyOffset + 2, true);
      sampleRate = view.getUint32(bodyOffset + 4, true);
      byteRate = view.getUint32(bodyOffset + 8, true);
      blockAlign = view.getUint16(bodyOffset + 12, true);
      bitDepth = view.getUint16(bodyOffset + 14, true);
    }
    if (id === 0x64617461) dataBytes = size;
    offset = bodyOffset + size + (size % 2);
  }
  if (encoding !== 1 || channels !== 1 || bitDepth !== 16 || !sampleRate || !blockAlign ||
      blockAlign !== 2 || byteRate !== sampleRate * blockAlign || !dataBytes || dataBytes % blockAlign !== 0) return undefined;
  const duration = Math.ceil((dataBytes / byteRate) * 1000);
  return Number.isSafeInteger(duration) && duration > 0 ? duration : undefined;
}

function text(view: DataView, start: number, end: number): string {
  let result = "";
  for (let offset = start; offset < end; offset++) result += String.fromCharCode(u8(view, offset, end));
  return result;
}

// iTunSMPB (moov/udta/meta/ilst/----) records encoder priming and padding in frames. Optional: any problem means "no tag".
function iTunSMPB(view: DataView, moov: Box): { priming: number; remainder: number; valid: number } | undefined {
  try {
    const udta = child(view, moov, "udta");
    const meta = udta && child(view, udta, "meta");
    const ilst = meta && boxes(view, meta.bodyStart + 4, meta.end).find(box => box.type === "ilst");
    if (!ilst) return undefined;
    for (const item of boxes(view, ilst.bodyStart, ilst.end)) {
      if (item.type !== "----") continue;
      const parts = boxes(view, item.bodyStart, item.end);
      const name = parts.find(box => box.type === "name");
      const data = parts.find(box => box.type === "data");
      if (!name || !data || text(view, name.bodyStart + 4, name.end) !== "iTunSMPB") continue;
      const fields = text(view, data.bodyStart + 8, data.end).trim().split(/\s+/);
      if (fields.length < 4 || !fields.slice(1, 4).every(field => /^[0-9a-fA-F]{1,16}$/.test(field))) return undefined;
      const [priming, remainder, valid] = fields.slice(1, 4).map(field => parseInt(field, 16));
      if (![priming, remainder, valid].every(Number.isSafeInteger)) return undefined;
      return { priming, remainder, valid };
    }
    return undefined;
  } catch {
    return undefined;
  }
}

// An edit list with one non-empty entry says where playback starts and ends in movie time.
function elstFrames(view: DataView, trak: Box, movieTimescale: number, trackTimescale: number): number | undefined {
  try {
    const edts = child(view, trak, "edts");
    const elst = edts && child(view, edts, "elst");
    if (!elst || u32(view, elst.bodyStart + 4, elst.end) !== 1) return undefined;
    const version = u8(view, elst.bodyStart, elst.end);
    const offset = elst.bodyStart + 8;
    let segment: number;
    let mediaTime: number;
    if (version === 1) {
      if (offset + 20 > elst.end) malformed();
      const large = view.getBigUint64(offset, false);
      if (large > BigInt(Number.MAX_SAFE_INTEGER)) return undefined;
      segment = Number(large);
      mediaTime = Number(view.getBigInt64(offset + 8, false));
    } else {
      segment = u32(view, offset, elst.end);
      if (offset + 12 > elst.end) malformed();
      mediaTime = view.getInt32(offset + 4, false);
    }
    if (mediaTime < 0 || movieTimescale === 0) return undefined;
    const frames = Math.ceil(segment * trackTimescale / movieTimescale);
    return Number.isSafeInteger(frames) ? frames : undefined;
  } catch {
    return undefined;
  }
}

// Priming and padding may only be removed when small: at most 4096 frames and 10% of the track.
function trimmedFrames(total: number, valid: number | undefined): number | undefined {
  if (valid === undefined || valid <= 0 || valid > total) return undefined;
  return total - valid <= Math.min(4096, Math.floor(total * 0.1)) ? valid : undefined;
}

// Duration comes from the stts sample table (what a decoder schedules). An iTunSMPB tag or an elst may trim
// encoder priming and padding, but only within bounds; the least-trimmed valid candidate wins.
export function mp4AudioDurationMs(data: ArrayBuffer): number | undefined {
  try {
    const view = new DataView(data);
    const top = boxes(view, 0, data.byteLength);
    if (top[0]?.type !== "ftyp" || top.some(box => box.type === "moof")) return undefined;
    const moovs = top.filter(box => box.type === "moov");
    if (moovs.length !== 1) return undefined;
    const moov = moovs[0];
    const mvhd = child(view, moov, "mvhd");
    const movieTimescale = mvhd ? u32(view, mvhd.bodyStart + (u8(view, mvhd.bodyStart, mvhd.end) === 1 ? 20 : 12), mvhd.end) : 0;
    const tag = iTunSMPB(view, moov);
    let durationMs = 0;
    let audioTracks = 0;
    for (const trak of boxes(view, moov.bodyStart, moov.end).filter(box => box.type === "trak")) {
      const mdia = child(view, trak, "mdia");
      const hdlr = mdia && child(view, mdia, "hdlr");
      if (!mdia || !hdlr || fourCC(view, hdlr.bodyStart + 8, hdlr.end) !== "soun") continue;
      const mdhd = child(view, mdia, "mdhd");
      const minf = child(view, mdia, "minf");
      const stbl = minf && child(view, minf, "stbl");
      const stts = stbl && child(view, stbl, "stts");
      const stsz = stbl && child(view, stbl, "stsz");
      if (!mdhd || !stts || !stsz) malformed();

      const version = u8(view, mdhd.bodyStart, mdhd.end);
      const timescale = u32(view, mdhd.bodyStart + (version === 1 ? 20 : 12), mdhd.end);
      if (timescale === 0) malformed();

      let units = 0;
      let samples = 0;
      const entries = u32(view, stts.bodyStart + 4, stts.end);
      for (let i = 0; i < entries; i++) {
        const offset = stts.bodyStart + 8 + i * 8;
        const count = u32(view, offset, stts.end);
        const delta = u32(view, offset + 4, stts.end);
        units += count * delta;
        samples += count;
        if (!Number.isSafeInteger(units) || !Number.isSafeInteger(samples)) malformed();
      }
      if (u32(view, stsz.bodyStart + 8, stsz.end) !== samples) malformed();

      const tagValid = tag && Math.abs(tag.priming + tag.remainder + tag.valid - units) <= 1024 ? tag.valid : undefined;
      const trimmed = [trimmedFrames(units, tagValid), trimmedFrames(units, elstFrames(view, trak, movieTimescale, timescale))]
        .filter((frames): frames is number => frames !== undefined);
      const frames = trimmed.length ? Math.max(...trimmed) : units;

      const scaled = frames * 1000;
      if (!Number.isSafeInteger(scaled)) malformed();
      durationMs = Math.max(durationMs, Math.ceil(scaled / timescale));
      audioTracks++;
    }
    if (audioTracks === 0 || durationMs === 0 || !Number.isSafeInteger(durationMs)) return undefined;
    // A client could declare a tiny stts to pay for less audio, so cap the implied bitrate.
    if (data.byteLength / durationMs > MAX_MP4_BYTES_PER_MS) return undefined;
    return durationMs;
  } catch {
    return undefined;
  }
}

export function audioDurationMs(data: ArrayBuffer): number | undefined {
  const view = new DataView(data);
  if (data.byteLength >= 4 && view.getUint32(0, false) === 0x52494646) return wavDurationMs(data);
  if (data.byteLength >= 8 && view.getUint32(4, false) === 0x66747970) return mp4AudioDurationMs(data);
  return undefined;
}
