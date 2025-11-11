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
    
    func playSegment(at fileURL: URL) {
        stop()
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true, options: [])
            
            let data = try Data(contentsOf: fileURL)
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            print("PlaybackService: failed to play \(fileURL): \(error)")
        }
    }
    
    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
