// WAV 读取器测试（新增）：手工构造 RIFF 字节流验证解析。

import XCTest
@testable import LiveSubCore

final class WAVReaderTests: XCTestCase {
    private func u16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// 构造 PCM16 WAV（仅测试用）。
    private func makeWAV(sampleRate: Int, channels: Int, bits: Int, samples: [Int16]) -> Data {
        var pcm = Data()
        for s in samples {
            let u = UInt16(bitPattern: s)
            pcm.append(UInt8(u & 0xFF))
            pcm.append(UInt8((u >> 8) & 0xFF))
        }
        let byteRate = sampleRate * channels * bits / 8
        let blockAlign = channels * bits / 8

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(u32(UInt32(36 + pcm.count)))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(u32(16))
        d.append(u16(1))                       // PCM
        d.append(u16(UInt16(channels)))
        d.append(u32(UInt32(sampleRate)))
        d.append(u32(UInt32(byteRate)))
        d.append(u16(UInt16(blockAlign)))
        d.append(u16(UInt16(bits)))
        d.append(contentsOf: Array("data".utf8))
        d.append(u32(UInt32(pcm.count)))
        d.append(pcm)
        return d
    }

    func testParsesMonoPCM16() throws {
        let samples: [Int16] = [0, 16384, -16384, -32768, 32767]
        let data = makeWAV(sampleRate: 16000, channels: 1, bits: 16, samples: samples)
        let audio = try WAVReader.read(data: data)

        XCTAssertEqual(audio.sampleRate, 16000)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.samples.count, samples.count)
        XCTAssertEqual(audio.samples[0], 0, accuracy: 1e-4)
        XCTAssertEqual(audio.samples[1], 0.5, accuracy: 1e-3)
        XCTAssertEqual(audio.samples[2], -0.5, accuracy: 1e-3)
        XCTAssertEqual(audio.samples[3], -1.0, accuracy: 1e-6)
        XCTAssertEqual(audio.samples[4], 0.99997, accuracy: 1e-3)
    }

    func testRejectsUnsupportedFormat() {
        let data = makeWAV(sampleRate: 16000, channels: 1, bits: 8, samples: [0])
        XCTAssertThrowsError(try WAVReader.read(data: data))
    }
}