// 麦克风采集：AVAudioEngine → 降混/重采样 → 100ms i16 块。
//
// 采集回调在音频线程 —— 这里只做纯计算 + 非阻塞投递（Resampler + onChunk→ChunkQueue），
// 与 ReaLingo 桌面版 Pipe 的形状完全一致。

import AVFoundation

final class MicCapture {
    private let engine = AVAudioEngine()
    private var resampler: Resampler?
    private var carry: [Int16] = []
    private(set) var running = false

    /// 每 1600 样本（100ms）回调一次。音频线程调用，勿阻塞。
    var onChunk: (([Int16]) -> Void)?

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

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "LiveSub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "音频输入格式无效"])
        }
        resampler = Resampler(inRate: Int(format.sampleRate), outRate: AudioConstants.targetRate)
        carry.removeAll()

        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

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