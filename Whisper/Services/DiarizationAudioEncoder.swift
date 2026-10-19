//
//  DiarizationAudioEncoder.swift
//  Whisper
//

import AVFoundation
import Foundation

/// Cuts slices out of a recording and re-encodes them so diarization uploads stay small.
/// Audio is streamed in about one-second buffers, so the full recording is never loaded into memory.
enum DiarizationAudioEncoder {
    enum EncodingError: LocalizedError {
        case unsupportedChannelCount(Int)
        case invalidRange
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .unsupportedChannelCount(let count):
                return "Diarization expects mono audio, found \(count) channels."
            case .invalidRange:
                return "The requested audio range is outside the recording."
            case .emptyOutput:
                return "Encoded audio was empty."
            }
        }
    }

    static let bitRate = 32_000

    static func duration(of source: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: source)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { throw EncodingError.invalidRange }
        return TimeInterval(file.length) / sampleRate
    }

    /// Writes `[start, start + duration)` of `source` to a temporary AAC/M4A file.
    /// The caller owns the returned file and should delete it once it is no longer needed.
    static func encodeChunk(source: URL, start: TimeInterval, duration: TimeInterval) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate
            ]
            try writeSegment(
                from: input,
                start: start,
                duration: duration,
                to: outputURL,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )

            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else {
                throw EncodingError.emptyOutput
            }
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Produces a 16-bit PCM WAV clip of `[start, start + duration)` and returns its bytes.
    static func encodeReferenceClip(source: URL, start: TimeInterval, duration: TimeInterval) throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-ref-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        try writeSegment(
            from: input,
            start: start,
            duration: duration,
            to: outputURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let data = try Data(contentsOf: outputURL)
        guard !data.isEmpty else { throw EncodingError.emptyOutput }
        return data
    }

    private static func writeSegment(
        from input: AVAudioFile,
        start: TimeInterval,
        duration: TimeInterval,
        to outputURL: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws {
        let format = input.processingFormat
        guard format.channelCount == 1 else {
            throw EncodingError.unsupportedChannelCount(Int(format.channelCount))
        }

        let sampleRate = format.sampleRate
        let startFrame = AVAudioFramePosition((start * sampleRate).rounded())
        let requestedFrames = AVAudioFramePosition((duration * sampleRate).rounded())
        let totalFrames = input.length
        guard startFrame >= 0, startFrame < totalFrames, requestedFrames > 0 else {
            throw EncodingError.invalidRange
        }
        var remaining = min(requestedFrames, totalFrames - startFrame)
        input.framePosition = startFrame

        // The output file is created and released inside this function so it is finalized before returning.
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: interleaved
        )

        let bufferCapacity = AVAudioFrameCount(max(1, sampleRate.rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
            throw EncodingError.invalidRange
        }

        while remaining > 0 {
            let framesToRead = AVAudioFrameCount(min(AVAudioFramePosition(bufferCapacity), remaining))
            try input.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
}
