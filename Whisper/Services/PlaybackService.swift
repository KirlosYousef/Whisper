//
//  PlaybackService.swift
//  Whisper
//
//  Created by Kirlos Yousef on 11/11/2025.
//

import Foundation
import AVFoundation

final class PlaybackService: NSObject, AVAudioPlayerDelegate {
    static let shared = PlaybackService()
    
    private var player: AVAudioPlayer?
    private var rangeEndTimer: Timer?
    private var playbackEnd: TimeInterval = .greatestFiniteMagnitude
    private var onFinish: (() -> Void)?
    
    func playSegment(at fileURL: URL) {
        play(url: fileURL, start: 0, end: .greatestFiniteMagnitude)
    }

    func play(url: URL, start: TimeInterval, end: TimeInterval, onFinish: (() -> Void)? = nil) {
        stop()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true, options: [])
            
            let data = try Data(contentsOf: url)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            let clampedStart = max(0, min(start, player.duration))
            player.currentTime = clampedStart
            self.player = player
            self.playbackEnd = end > clampedStart ? end : player.duration
            self.onFinish = onFinish
            player.play()
            startRangeTimer()
        } catch {
            print("PlaybackService: failed to play \(url): \(error)")
        }
    }
    
    func stop() {
        rangeEndTimer?.invalidate()
        rangeEndTimer = nil
        onFinish = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishRangePlayback()
    }

    private func startRangeTimer() {
        rangeEndTimer?.invalidate()
        guard playbackEnd.isFinite, playbackEnd < 24 * 60 * 60 else { return }
        rangeEndTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkRangeEnd()
        }
        if let rangeEndTimer {
            RunLoop.main.add(rangeEndTimer, forMode: .common)
        }
    }

    private func checkRangeEnd() {
        guard let player else { return }
        if player.currentTime >= playbackEnd - 0.02 {
            finishRangePlayback()
        }
    }

    private func finishRangePlayback() {
        let finish = onFinish
        rangeEndTimer?.invalidate()
        rangeEndTimer = nil
        onFinish = nil
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        if let finish {
            DispatchQueue.main.async {
                finish()
            }
        }
    }
}
