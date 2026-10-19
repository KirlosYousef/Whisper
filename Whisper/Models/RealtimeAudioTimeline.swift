import Foundation

/// Tracks the PCM16 24 kHz stream position so every append starts on a whole millisecond.
struct RealtimeAudioTimeline {
    static let bytesPerMillisecond = 48

    struct Append: Equatable {
        let data: Data
        let startMs: Int
    }

    private var pending = Data()
    /// Absolute byte position of `pending[0]` in the stream. Always a multiple of `bytesPerMillisecond`.
    private var pendingStartByte: Int

    init(startOffsetMs: Int) {
        pendingStartByte = max(0, startOffsetMs) * Self.bytesPerMillisecond
    }

    var bufferedByteCount: Int {
        pending.count
    }

    mutating func enqueue(_ data: Data) {
        pending.append(data)
    }

    /// Returns whole-millisecond appends of at most `maxBytes` each (one append when `maxBytes` is nil).
    /// A sub-millisecond remainder stays buffered unless `flushRemainder` is true, in which case it is
    /// padded with silence to a whole millisecond and emitted.
    mutating func takeAppends(maxBytes: Int?, flushRemainder: Bool) -> [Append] {
        let bytesPerMs = Self.bytesPerMillisecond
        if flushRemainder {
            let padding = (bytesPerMs - pending.count % bytesPerMs) % bytesPerMs
            if padding > 0 {
                pending.append(Data(count: padding))
            }
        }
        let available = pending.count - pending.count % bytesPerMs
        let chunkLimit: Int
        if let maxBytes {
            chunkLimit = max(bytesPerMs, maxBytes - maxBytes % bytesPerMs)
        } else {
            chunkLimit = available
        }

        var appends: [Append] = []
        var consumed = 0
        while consumed < available {
            let size = min(chunkLimit, available - consumed)
            let slice = pending.subdata(in: consumed..<(consumed + size))
            appends.append(Append(data: slice, startMs: (pendingStartByte + consumed) / bytesPerMs))
            consumed += size
        }

        if consumed > 0 {
            pending = pending.subdata(in: consumed..<pending.count)
            pendingStartByte += consumed
        }
        return appends
    }

    /// Drops the oldest audio, in whole milliseconds, until at most `maxBufferedBytes` remain buffered.
    mutating func dropOldest(toFit maxBufferedBytes: Int) {
        let bytesPerMs = Self.bytesPerMillisecond
        let cap = max(0, maxBufferedBytes)
        guard pending.count > cap else { return }

        let excess = pending.count - cap
        let roundedExcess = (excess + bytesPerMs - 1) / bytesPerMs * bytesPerMs
        let wholeBytes = pending.count - pending.count % bytesPerMs
        let dropBytes = min(roundedExcess, wholeBytes)
        guard dropBytes > 0 else { return }

        pending = pending.subdata(in: dropBytes..<pending.count)
        pendingStartByte += dropBytes
    }

    mutating func reset(startOffsetMs: Int) {
        pending = Data()
        pendingStartByte = max(0, startOffsetMs) * Self.bytesPerMillisecond
    }
}
