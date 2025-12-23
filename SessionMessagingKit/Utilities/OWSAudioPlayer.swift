// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFoundation
import SessionUtilitiesKit

// MARK: - AudioPlaybackState

public enum AudioPlaybackState: Int {
    case stopped
    case playing
    case paused
}

// MARK: - OWSAudioBehavior

public enum OWSAudioBehavior: UInt, Equatable {
    case unknown
    case playback
    case audioMessagePlayback
    case playAndRecord
    case call
}

// MARK: - OWSAudioPlayerDelegate Protocol

public protocol OWSAudioPlayerDelegate: AnyObject {
    @MainActor var audioPlaybackState: AudioPlaybackState { get set }
    
    @MainActor func setAudioProgress(_ progress: CGFloat, duration: CGFloat)
    @MainActor func showInvalidAudioFileAlert()
    @MainActor func audioPlayerDidFinishPlaying(_ player: OWSAudioPlayer, successfully flag: Bool)
}

// MARK: - OWSAudioPlayerDelegateStub

/// A no-op delegate implementation to be used when we don't need a delegate.
class OWSAudioPlayerDelegateStub: OWSAudioPlayerDelegate {
    var audioPlaybackState: AudioPlaybackState = .stopped
    
    func setAudioProgress(_ progress: CGFloat, duration: CGFloat) {
        // Do nothing
    }
    
    func showInvalidAudioFileAlert() {
        // Do nothing
    }
    
    func audioPlayerDidFinishPlaying(_ player: OWSAudioPlayer, successfully flag: Bool) {
        // Do nothing
    }
}

// MARK: - OWSAudioPlayer

public class OWSAudioPlayer: NSObject {
    
    // MARK: - Properties
    
    private let dependencies: Dependencies
    private let mediaUrl: URL
    @MainActor private var audioPlayer: AVAudioPlayer?
    private var audioPlayerPoller: Timer?
    private let audioActivity: AudioActivity
    
    public weak var delegate: OWSAudioPlayerDelegate?
    @MainActor public var isLooping: Bool = false
    
    @MainActor public var isPlaying: Bool {
        return delegate?.audioPlaybackState == .playing
    }
    
    @MainActor public var currentTime: TimeInterval {
        get { audioPlayer?.currentTime ?? 0 }
        set { audioPlayer?.currentTime = newValue }
    }
    
    @MainActor public var playbackRate: Float {
        get { audioPlayer?.rate ?? 1.0 }
        set { audioPlayer?.rate = newValue }
    }
    
    @MainActor public var duration: TimeInterval {
        return audioPlayer?.duration ?? 0
    }
    
    // MARK: - Initialization
    
    public convenience init(
        mediaUrl: URL,
        audioBehavior: OWSAudioBehavior,
        using dependencies: Dependencies
    ) {
        self.init(
            mediaUrl: mediaUrl,
            audioBehavior: audioBehavior,
            delegate: OWSAudioPlayerDelegateStub(),
            using: dependencies
        )
    }
    
    public init(
        mediaUrl: URL,
        audioBehavior: OWSAudioBehavior,
        delegate: OWSAudioPlayerDelegate?,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.mediaUrl = mediaUrl
        self.delegate = delegate
        self.audioActivity = AudioActivity(
            audioDescription: "OWSAudioPlayer \(mediaUrl)", // stringlint:ignore
            behavior: audioBehavior,
            using: dependencies
        )
        
        super.init()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground(_:)),
            name: .sessionDidEnterBackground,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: self)
        
        Task { @MainActor [delegate, audioPlayer, audioPlayerPoller, audioActivity, dependencies] in
            delegate?.audioPlaybackState = .stopped
            audioPlayer?.pause()
            audioPlayerPoller?.invalidate()
            delegate?.setAudioProgress(0, duration: 0)
            dependencies[singleton: .audioSession].endAudioActivity(audioActivity)
        }
    }
    
    // MARK: - Notification Handlers
    
    @objc private func applicationDidEnterBackground(_ notification: Notification) {
        Task { @MainActor in
            stop()
        }
    }
    
    // MARK: - Public Methods
    
    @MainActor public func play() {
        playWithAudioActivity(audioActivity)
    }
    
    @MainActor public func playWithAudioActivity(_ audioActivity: AudioActivity) {
        audioPlayerPoller?.invalidate()
        
        delegate?.audioPlaybackState = .playing
        
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        
        if audioPlayer == nil {
            do {
                let player = try AVAudioPlayer(contentsOf: mediaUrl as URL)
                player.enableRate = true
                player.delegate = self
                
                if isLooping {
                    player.numberOfLoops = -1
                }
                
                self.audioPlayer = player
            } catch {
                stop()
                
                let nsError = error as NSError
                if nsError.domain == NSOSStatusErrorDomain &&
                   (nsError.code == Int(kAudioFileInvalidFileError) ||
                    nsError.code == Int(kAudioFileStreamError_InvalidFile)) {
                    delegate?.showInvalidAudioFileAlert()
                }
                
                return
            }
        }
        
        audioPlayer?.play()
        audioPlayerPoller?.invalidate()
        
        
        audioPlayerPoller = Timer.scheduledTimerOnMainThread(
            withTimeInterval: 0.05,
            repeats: true,
            using: dependencies
        ) { [weak self] timer in
            self?.audioPlayerUpdated(timer)
        }
        
        // Prevent device from sleeping while playing audio
        dependencies[singleton: .deviceSleepManager].addBlock(blockObject: self)
    }
    
    @MainActor public func pause() {
        delegate?.audioPlaybackState = .paused
        audioPlayer?.pause()
        audioPlayerPoller?.invalidate()
        
        if let player = audioPlayer {
            delegate?.setAudioProgress(CGFloat(player.currentTime), duration: CGFloat(player.duration))
        }
        
        endAudioActivities()
        dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: self)
    }
    
    @MainActor public func stop() {
        delegate?.audioPlaybackState = .stopped
        audioPlayer?.pause()
        audioPlayerPoller?.invalidate()
        delegate?.setAudioProgress(0, duration: 0)
        
        endAudioActivities()
        dependencies[singleton: .deviceSleepManager].removeBlock(blockObject: self)
    }
    
    @MainActor public func togglePlayState() {
        if isPlaying {
            pause()
        } else {
            playWithAudioActivity(audioActivity)
        }
    }
    
    // MARK: - Private Methods
    
    private func endAudioActivities() {
        dependencies[singleton: .audioSession].endAudioActivity(audioActivity)
    }
    
    @objc private func audioPlayerUpdated(_ timer: Timer) {
        Task { @MainActor in
            if let player = audioPlayer {
                delegate?.setAudioProgress(CGFloat(player.currentTime), duration: CGFloat(player.duration))
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension OWSAudioPlayer: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stop()
            delegate?.audioPlayerDidFinishPlaying(self, successfully: flag)
        }
    }
}
