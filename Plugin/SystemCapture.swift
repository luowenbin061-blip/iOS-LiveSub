// 系统声音采集（ReplayKit 应用内音频）——录的是**宿主 App 自己的音频输出流**，
// 不是从麦克风拾音：网页播放器 / 内置播放器、戴不戴耳机、静音拨片，理论上都照常。
//
// 代价（先知道）：
//   - 系统会出现「屏幕录制」指示条（系统给 ReplayKit 的标志，去不掉）
//   - 系统同时在录画面：我们只取 audioApp 音轨，但仍有额外开销
//   - 首次使用会弹「屏幕录制」授权
//
// 采集回调在 ReplayKit 的后台队列 —— 只做纯计算 + 非阻塞投递（与 MicCapture 同约定）。

import AVFoundation
import AudioToolbox
import CoreMedia
import ReplayKit

/// 采集源统一接口：麦克风 / 系统声音 二选一接进同一条管线。
protocol AudioCapturing: AnyObject {
    var running: Bool { get }
    var onChunk: (([Int16]) -> Void)? { get set }
    var onInterrupted: (() -> Void)? { get set }
    var onRecovered: (() -> Void)? { get set }
    func start() throws
    func stop()
    func ensureRunning()
}

final class SystemCapture: AudioCapturing {
    private let recorder = RPScreenRecorder.shared()
    private var resampler: Resampler?
    private var resamplerRate = 0
    private var carry: [Int16] = []
    private(set) var running = false

    var onChunk: (([Int16]) -> Void)?
    var onInterrupted: (() -> Void)?
    var onRecovered: (() -> Void)?

    func start() throws {
        guard !running else { return }
        guard recorder.isAvailable else {
            throw NSError(domain: "LiveSub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "本机不支持屏幕录制采集"])
        }
        recorder.isMicrophoneEnabled = false
        running = true
        recorder.startCapture { [weak self] sampleBuffer, type, _ in
            guard type == .audioApp else { return }
            self?.handle(sampleBuffer)
        } completionHandler: { [weak self] error in
            guard let self, error != nil else { return }
            // 启动失败（多为屏幕录制权限被拒）
            DispatchQueue.main.async {
                self.running = false
                self.onInterrupted?()
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        recorder.stopCapture { _ in }
    }

    /// 健康巡查：标称在运行、系统却停了录制，就重开。
    func ensureRunning() {
        guard running, !recorder.isRecording else { return }
        running = false
        try? start()
    }

    // MARK: - 采样转换

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0, asbd.mSampleRate > 0 else { return }

        // 采样率变化（换路由等）时重建重采样器
        let rate = Int(asbd.mSampleRate)
        if rate != resamplerRate {
            resamplerRate = rate
            resampler = Resampler(inRate: rate, outRate: AudioConstants.targetRate)
            carry.removeAll()
        }

        var abl = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard st == noErr else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let list = UnsafeMutableAudioBufferListPointer(&abl)
        let chDiv = Float(channels)

        // 降混成单声道 [Float]（与 MicCapture 同一约定）
        var mono = [Float](repeating: 0, count: frames)
        if isFloat {
            if isNonInterleaved {
                for c in 0..<min(channels, list.count) {
                    guard let p = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<frames { mono[f] += p[f] / chDiv }
                }
            } else if list.count > 0, let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += p[f * channels + c] }
                    mono[f] = s / chDiv
                }
            }
        } else {
            if isNonInterleaved {
                for c in 0..<min(channels, list.count) {
                    guard let p = list[c].mData?.assumingMemoryBound(to: Int16.self) else { continue }
                    for f in 0..<frames { mono[f] += Float(p[f]) / 32768.0 / chDiv }
                }
            } else if list.count > 0, let p = list[0].mData?.assumingMemoryBound(to: Int16.self) {
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += Float(p[f * channels + c]) / 32768.0 }
                    mono[f] = s / chDiv
                }
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