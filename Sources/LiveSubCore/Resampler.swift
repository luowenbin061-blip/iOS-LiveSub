// 流式重采样到 16kHz 单声道 i16 —— 移植自 ReaLingo src-tauri/src/resample.rs（MIT）。
//
// 直接窗化 sinc：对每个输出样本在一个小数输入位置上求值，核为 Blackman 窗 sinc，
// 截止频率取两端奈奎斯特的较小者，因此任意比率都有真正的抗混叠
// （48000/16000 = 3，44100/16000 = 2.75625，朴素抽取做不到）。

import Foundation

public enum AudioConstants {
    /// 模型要求的采样率。
    public static let targetRate = 16_000
    /// 100 ms @ 16 kHz —— 实时接口示例使用的分块大小。
    public static let chunkSamples = 1600
}

public final class Resampler {
    private static let half = 16  // 32 抽头；对语音足够

    private let step: Double      // 每个输出样本消耗的输入样本数
    private var pos: Double       // buf 内的小数读取位置
    private var buf: [Float]
    private let cutoff: Double    // 归一化到输入采样率，0..0.5
    private let passthrough: Bool

    public init(inRate: Int, outRate: Int) {
        let step = Double(inRate) / Double(outRate)
        // 0.92 留出过渡带，阻带才真正衰减。
        let cutoff = 0.5 * min(Double(outRate) / Double(inRate), 1.0) * 0.92
        self.step = step
        self.pos = Double(Self.half)
        self.buf = [Float](repeating: 0, count: Self.half)  // 左侧上下文
        self.cutoff = cutoff
        self.passthrough = inRate == outRate
    }

    /// 喂入已降混的单声道样本；返回本次转换出的 i16（流式拼接）。
    public func push(_ input: [Float]) -> [Int16] {
        if passthrough {
            return input.map { Self.toInt16($0) }
        }
        buf.append(contentsOf: input)
        var out: [Int16] = []

        while Int(pos.rounded(.down)) + Self.half < buf.count {
            let center = pos
            let first = Int(center.rounded(.down)) - Self.half + 1
            var acc = 0.0
            var wsum = 0.0
            for k in 0..<(2 * Self.half) {
                let idx = first + k
                if idx < 0 { continue }
                let dx = center - Double(idx)
                let w = Self.sinc(2.0 * cutoff * dx) * Self.blackman(dx / Double(Self.half))
                acc += Double(buf[idx]) * w
                wsum += w
            }
            // 按窗和归一化，任意相位下直流增益都是 1。
            out.append(Self.toInt16(Float(acc / max(wsum, 1e-9))))
            pos += step
        }

        // 丢掉不会再看的输入，保留 half 个左侧上下文。
        let keepFrom = max(Int(pos.rounded(.down)) - Self.half, 0)
        if keepFrom > 0 {
            buf.removeFirst(keepFrom)
            pos -= Double(keepFrom)
        }
        return out
    }

    private static func sinc(_ x: Double) -> Double {
        if abs(x) < 1e-9 { return 1.0 }
        let p = Double.pi * x
        return sin(p) / p
    }

    /// [-1, 1] 上的 Blackman 窗；窗外为 0。
    private static func blackman(_ t: Double) -> Double {
        if abs(t) >= 1.0 { return 0.0 }
        let p = Double.pi * t
        return 0.42 + 0.5 * cos(p) + 0.08 * cos(2.0 * p)
    }

    private static func toInt16(_ s: Float) -> Int16 {
        let clamped = min(max(s, -1.0), 1.0)
        return Int16(clamped * 32767.0)
    }
}

/// 交错帧降混成单声道（多通道取平均）。
public func downmix(_ interleaved: [Float], channels: Int) -> [Float] {
    if channels <= 1 { return interleaved }
    var out: [Float] = []
    out.reserveCapacity(interleaved.count / max(channels, 1))
    var i = 0
    while i + channels <= interleaved.count {
        var sum: Float = 0
        for c in 0..<channels { sum += interleaved[i + c] }
        out.append(sum / Float(channels))
        i += channels
    }
    return out
}