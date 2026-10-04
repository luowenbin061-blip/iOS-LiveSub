// 麦克风采集：AVAudioEngine → 降混/重采样 → 100ms i16 块。
//
// 采集回调在音频线程 —— 这里只做纯计算 + 非阻塞投递（Resampler + onChunk→ChunkQueue）。
//
// v0.6 加固：iOS 上输入引擎会因各种原因**静默停产** —— 路由/格式变化（插拔耳机、
// 视频开始播放引发会话配置变化）、系统打断（来电/Siri）、宿主抢占音频会话。
// 引擎死掉后 WebSocket 还开着、却没有音频上行，表现就是「翻译几句就不动了」。
// 所以监听引擎配置变化/打断/路由变化，并在状态巡查里自动把引擎拉回来。

import AVFoundation

final class MicCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    private var carry: [Int16] = []
    private(set) var running = false
    private var observersInstalled = false

    /// 每 1600 样本（100ms）回调一次。音频线程调用，勿阻塞。
    var onChunk: (([Int16]) -> Void)?
    /// 采集被系统打断 / 拉不起来（主线程回调）。
    var onInterrupted: (() -> Void)?
    /// 采集恢复成功（主线程回调）。
    var onRecovered: (() -> Void)?

    /// 麦克风权限（未决时弹窗申请，回调回主线程）。
    static func ensurePermission(_ completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        default:
            session.requestRecordPermission { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }

    func start() throws {
        guard !running else { return }

        let session = AVAudioSession.sharedInstance()
        // playAndRecord：与宿主播放共存、不打断视频。
        // defaultToSpeaker：playAndRecord 默认走听筒，不设的话视频声会被切到听筒。
        // 刻意不用 .voiceChat —— 它的 AEC 会把扬声器里的视频声当回声消掉，而那正是我们要的。
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
        try session.setActive(true)
        try startEngine()
        running = true
        installObservers()
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// 状态巡查用：标称在运行、引擎却停了，就拉回来。
    func ensureRunning() {
        guard running, !engine.isRunning else { return }
        restart()
    }

    // MARK: - 引擎启停

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LiveSub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "音频输入格式无效"])
        }
        resampler = Resampler(inRate: Int(format.sampleRate), outRate: AudioConstants.targetRate)
        carry.removeAll()
        input.removeTap(onBus: 0)  // 保险：总线上已有 tap 时再装会直接崩
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard running else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try startEngine()
            onRecovered?()
        } catch {
            onInterrupted?()  // 多半还在被打断：等下一次巡查再试
        }
    }

    // MARK: - 系统通知

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.ensureRunning()
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] _ in
            self?.ensureRunning()
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard running,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            onInterrupted?()
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        case .ended:
            let optsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume) {
                restart()
            }
        @unknown default:
            break
        }
    }

    // MARK: - 音频处理

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        guard frames > 0, chCount > 0 else { return }

        // 降混单声道（话筒通常非交错；交错格式也兜住）。
        var mono = [Float](repeating: 0, count: frames)
        if chCount == 1 {
            mono = Array(UnsafeBufferPointer(start: channels[0], count: frames))
        } else if buffer.format.isInterleaved {
            let base = channels[0]
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<chCount { sum += base[f * chCount + c] }
                mono[f] = sum / Float(chCount)
            }
        } else {
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<chCount { sum += channels[c][f] }
                mono[f] = sum / Float(chCount)
            }
        }

        guard let resampler else { return }
        carry.append(contentsOf: resampler.push(mono))
        let chunkSize = AudioConstants.chunkSamples
        while carry.count >= chunkSize {
            let chunk = Array(carry[0..<chunkSize])
            carry.removeFirst(chunkSize)
            onChunk?(chunk)
        }
    }
}