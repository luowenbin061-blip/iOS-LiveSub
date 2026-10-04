// 移植自 ReaLingo src-tauri/src/resample.rs 的 4 个单测（MIT）：
// 整数比、分数比、旁路精确性、降混。

import XCTest
@testable import LiveSubCore

final class ResamplerTests: XCTestCase {
    private func rms(_ v: [Int16]) -> Double {
        guard !v.isEmpty else { return 0 }
        let sum = v.reduce(0.0) { $0 + pow(Double($1) / 32767.0, 2) }
        return (sum / Double(v.count)).squareRoot()
    }

    /// 以 512 样本的块喂入 —— 走的是流式路径，不是一次性大块。
    private func run(inRate: Int, freq: Double) -> [Int16] {
        let r = Resampler(inRate: inRate, outRate: AudioConstants.targetRate)
        let input: [Float] = (0..<inRate).map { n in
            Float(sin(2.0 * Double.pi * freq * Double(n) / Double(inRate)))
        }
        var out: [Int16] = []
        var i = 0
        while i < input.count {
            let end = min(i + 512, input.count)
            out.append(contentsOf: r.push(Array(input[i..<end])))
            i = end
        }
        return out
    }

    func testIntegerRatio48k() {
        let out = run(inRate: 48_000, freq: 1000)
        XCTAssertLessThan(abs(out.count - 16_000), 64, "expected ~16000 samples, got \(out.count)")
        // 单位正弦的 RMS 是 1/sqrt(2)；重采样不能把信号吃掉。
        XCTAssertLessThan(abs(rms(out) - 0.707), 0.05, "rms drifted: \(rms(out))")
    }

    func testFractionalRatio44k1() {
        let out = run(inRate: 44_100, freq: 1000)
        XCTAssertLessThan(abs(out.count - 16_000), 64, "expected ~16000 samples, got \(out.count)")
        XCTAssertLessThan(abs(rms(out) - 0.707), 0.05, "rms drifted: \(rms(out))")
    }

    func testPassthroughIsExact() {
        let r = Resampler(inRate: AudioConstants.targetRate, outRate: AudioConstants.targetRate)
        XCTAssertEqual(r.push([1.0, -1.0, 0.0]), [32767, -32767, 0])
    }

    func testDownmixAveragesChannels() {
        XCTAssertEqual(downmix([1.0, 0.0, 0.5, 0.5], channels: 2), [0.5, 0.5])
    }
}