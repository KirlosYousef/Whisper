//
//  DiarizationAudioEncoderTests.swift
//  WhisperTests
//

import AVFoundation
import Foundation
import XCTest
@testable import Revera_AI

final class DiarizationAudioEncoderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizationAudioEncoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    /// Writes a 16 kHz mono 16-bit WAV containing a sine tone of the given length.
    private func makeToneWAV(seconds: Double, sampleRate: Double = 16_000) throws -> URL {
        let url = tempDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate)) * 0.5
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return url
    }

    func testDurationReportsSourceLength() throws {
        let source = try makeToneWAV(seconds: 65)
        XCTAssertEqual(try DiarizationAudioEncoder.duration(of: source), 65, accuracy: 0.01)
    }

    func testEncodeChunkProducesSmallAACFileWithRequestedDuration() throws {
        let source = try makeToneWAV(seconds: 65)

        let chunkURL = try DiarizationAudioEncoder.encodeChunk(source: source, start: 10, duration: 30)
        defer { try? FileManager.default.removeItem(at: chunkURL) }

        XCTAssertEqual(chunkURL.pathExtension, "m4a")
        let file = try AVAudioFile(forReading: chunkURL)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 30, accuracy: 0.1)

        let attributes = try FileManager.default.attributesOfItem(atPath: chunkURL.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 30 * 6 * 1024)
    }

    func testEncodeChunkRejectsRangeOutsideRecording() throws {
        let source = try makeToneWAV(seconds: 5)
        XCTAssertThrowsError(try DiarizationAudioEncoder.encodeChunk(source: source, start: 10, duration: 5))
    }

    func testEncodeReferenceClipProducesWAVOfRequestedLength() throws {
        let source = try makeToneWAV(seconds: 20)

        let data = try DiarizationAudioEncoder.encodeReferenceClip(source: source, start: 3, duration: 5)

        XCTAssertEqual(data.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(data[8..<12], Data("WAVE".utf8))

        let clipURL = tempDirectory.appendingPathComponent("clip.wav")
        try data.write(to: clipURL)
        let file = try AVAudioFile(forReading: clipURL)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 5, accuracy: 0.05)
    }
}
