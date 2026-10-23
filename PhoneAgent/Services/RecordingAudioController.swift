import Foundation
import Combine
import AVFoundation
import UIKit

@MainActor
final class RecordingAudioController: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Mode { case idle, preparing, recording, paused, playing }
    @Published private(set) var mode = Mode.idle
    @Published private(set) var seconds: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var state = ""
    @Published private(set) var error = ""
    var busy: Bool { mode != .idle }
    var reserve: ((UUID) -> Bool)?
    var release: ((UUID) -> Void)?
    var prepareAudio: (() async throws -> Void)?
    private var lease: UUID?
    private var generation = UUID()
    private var setup: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playbackEnd: Double?
    private var draft: PendingRecording?
    private var store: RecordingStore?
    private var active = false
    private var notifications: [NSObjectProtocol] = []
    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.didBecomeInactiveNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                // Our own category setup also emits a route notification.
                if notification.name == AVAudioSession.routeChangeNotification,
                   let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                Task { @MainActor [weak self] in
                    guard let self, self.active else { return }
                    self.stop(interrupted: true); self.state = "音频被系统打断，未自动恢复；请核对已保存的部分"
                }
            })
        }
    }
    deinit { notifications.forEach { NotificationCenter.default.removeObserver($0) }; timer?.cancel(); setup?.cancel() }
    private func claim() -> UUID? {
        guard !busy, UIApplication.shared.applicationState == .active else { return nil }
        let id = UUID()
        guard reserve?(id) == true else { error = "请先结束其他语音、任务、校准或播放，再录音或回听"; return nil }
        lease = id; generation = id; mode = .preparing; seconds = 0; error = ""; return id
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, lease == token, UIApplication.shared.applicationState == .active else { throw CancellationError() }
    }
    func record(title: String, store: RecordingStore) {
        guard let token = claim() else { return }; self.store = store; state = "正在准备本机录音"
        setup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAudio?(); try self.check(token)
                guard await AVAudioApplication.requestRecordPermission() else { throw AgentError.message("麦克风未授权，请在系统设置中允许后重试") }
                try self.check(token)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true); self.active = true
                let draft = try store.makePending(title: title); self.draft = draft
                let url = try store.audioURL(draft.id, pending: true)
                let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                recorder.delegate = self; recorder.isMeteringEnabled = true; self.recorder = recorder
                // Leave a one-second container margin below the import/transcription bound.
                guard recorder.prepareToRecord(), recorder.record(forDuration: 599) else { throw AgentError.message("无法开始录音，未完成文件保留在录音库中") }
                try self.check(token); self.mode = .recording; self.state = "正在本机录音"; self.setup = nil; self.tick(token)
            } catch {
                guard self.generation == token else { return }
                self.recorder?.delegate = nil; self.recorder?.stop(); self.recorder = nil
                self.draft = nil; self.finishLease(); self.store?.reload()
                self.error = (error as? AgentError)?.localizedDescription ?? "无法开始录音，未上传音频；请核对权限和空间"
            }
        }
    }
    func pauseOrResume() {
        guard let recorder else { return }
        if mode == .recording { recorder.pause(); mode = .paused; state = "录音已暂停" }
        else if mode == .paused {
            let remaining = 599 - recorder.currentTime
            guard remaining > 0 else { stop(); return }
            guard recorder.record(forDuration: remaining) else { stop(interrupted: true); error = "无法继续录音，已保留可用部分"; return }
            mode = .recording; state = "正在本机录音"
        }
    }
    func play(_ record: LocalRecording, store: RecordingStore, start: Double = 0, end: Double? = nil) {
        do { _ = try RecordingPlaybackRange.make(start: start, end: end, duration: record.duration) } catch { self.error = error.localizedDescription; return }
        guard let token = claim() else { return }; self.store = store
        setup = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareAudio?(); try self.check(token)
                let player = try AVAudioPlayer(contentsOf: store.audioURL(record.id))
                guard player.duration.isFinite, player.duration > 0, player.duration <= 600 else { throw AgentError.message("录音音频无效或超过时长范围") }
                let range = try RecordingPlaybackRange.make(start: start, end: end, duration: player.duration)
                let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]); try session.setActive(true); self.active = true
                self.player = player; player.delegate = self; self.playbackEnd = range.end
                guard player.prepareToPlay() else { throw AgentError.message("无法准备录音回听") }; try self.check(token)
                player.currentTime = range.start
                guard player.play() else { throw AgentError.message("无法播放录音") }
                self.mode = .playing; self.state = "正在回听 · " + record.title; self.setup = nil; self.tick(token)
            } catch {
                guard self.generation == token else { return }; self.player?.stop(); self.player = nil; self.finishLease()
                self.error = "无法播放录音，请核对文件后重试"
            }
        }
    }
    func stop(interrupted: Bool = false) {
        if mode == .preparing { state = "已取消音频准备" }
        else if mode == .playing { state = "回听已结束" }
        generation = UUID(); setup?.cancel(); setup = nil; timer?.cancel(); timer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let recorder {
            recorder.delegate = nil; recorder.stop(); self.recorder = nil
            if let draft, let store {
                do {
                    let file = try AVAudioFile(forReading: store.audioURL(draft.id, pending: true))
                    let duration = Double(file.length) / file.processingFormat.sampleRate
                    _ = try store.finalize(draft.id, duration: duration, interrupted: interrupted)
                    state = interrupted ? "已保存中断前的录音，请核对" : "录音已保存在本机"
                } catch { self.error = "录音未能完整入库，原文件保留在未完成录音中，可恢复或导出"; store.reload() }
            }
        }
        draft = nil; finishLease()
    }
    private func finishLease() {
        timer?.cancel(); timer = nil; setup = nil; mode = .idle; level = 0; playbackEnd = nil
        if active { active = false; try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        if let lease { self.lease = nil; release?(lease) }
    }
    private func tick(_ token: UUID) {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.generation == token else { return }
                if let recorder = self.recorder {
                    self.seconds = max(0, recorder.currentTime); recorder.updateMeters(); self.level = min(1, max(0, pow(10, Double(recorder.averagePower(forChannel: 0)) / 30)))
                    if self.seconds >= 599 { self.stop(); return }
                } else if let player = self.player { self.seconds = max(0, player.currentTime); if let end = self.playbackEnd, self.seconds >= end { self.stop(); return } }
            }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard let self, self.recorder === recorder else { return }; self.stop(interrupted: !flag) }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in guard let self, self.recorder === recorder else { return }; self.stop(interrupted: true) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in guard let self, self.player === player else { return }; self.stop(); if !flag { self.error = "回听未能完成，原录音仍保留" } }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in guard let self, self.player === player else { return }; self.stop(); self.error = "录音解码失败，原文件仍保留，可导出核对" }
    }
}
