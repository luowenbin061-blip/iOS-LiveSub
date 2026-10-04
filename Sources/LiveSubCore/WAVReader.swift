// 最小 RIFF/WAVE 解析（仅 PCM16）—— 服务「喂文件」调试模式与离线测试。
//
// 真机的正式采集不经过这里；这个读取器只负责把一段 WAV 样本交给
// Resampler → ChunkQueue → RealtimeClient 这条管线。

import Foundation

public enum WAVReaderError: Error, LocalizedError {
    case notRIFF
    case notWAVE
    case unsupportedFormat(audioFormat: Int, bitsPerSample: Int)
    case missingChunk(String)

    public var errorDescription: String? {
        switch self {
        case .notRIFF:            return "not a RIFF file"
        case .notWAVE:            return "not a WAVE file"
        case .unsupportedFormat(let f, let b):
            return "unsupported WAV format (audioFormat=\(f), bits=\(b)); only PCM16 is supported"
        case .missingChunk(let c): return "missing \(c) chunk"
        }
    }
}

public struct WAVAudio {
    public let sampleRate: Int
    public let channels: Int
    /// 交错浮点样本，范围 [-1, 1]。
    public let samples: [Float]
}

public enum WAVReader {
    public static func read(contentsOf url: URL) throws -> WAVAudio {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> WAVAudio {
        func u16(_ o: Int) -> UInt16 {
            UInt16(data[o]) | UInt16(data[o + 1]) << 8
        }
        func u32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o + 1]) << 8
                | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        func ascii(_ o: Int, _ count: Int) -> String {
            String(bytes: data[o..<(o + count)], encoding: .ascii) ?? ""
        }

        guard data.count >= 44 else { throw WAVReaderError.notRIFF }
        guard ascii(0, 4) == "RIFF" else { throw WAVReaderError.notRIFF }
        guard ascii(8, 4) == "WAVE" else { throw WAVReaderError.notWAVE }

        var fmtFound = false
        var audioFormat = 0
        var channels = 0
        var sampleRate = 0
        var bits = 0
        var payload: Data?

        var o = 12
        while o + 8 <= data.count {
            let id = ascii(o, 4)
            let size = Int(u32(o + 4))
            let body = o + 8
            if id == "fmt " {
                guard body + 16 <= data.count else { throw WAVReaderError.missingChunk("fmt ") }
                audioFormat = Int(u16(body))
                channels = Int(u16(body + 2))
                sampleRate = Int(u32(body + 4))
                bits = Int(u16(body + 14))
                fmtFound = true
            } else if id == "data" {
                let end = min(body + size, data.count)
                if end > body {
                    payload = data.subdata(in: body..<end)
                } else {
                    payload = Data()
                }
            }
            o = body + size + (size % 2)  // RIFF 块按偶数字节对齐
        }

        guard fmtFound else { throw WAVReaderError.missingChunk("fmt ") }
        guard audioFormat == 1 && bits == 16 && channels > 0 else {
            throw WAVReaderError.unsupportedFormat(audioFormat: audioFormat, bitsPerSample: bits)
        }
        guard let pcm = payload else { throw WAVReaderError.missingChunk("data") }

        var samples: [Float] = []
        samples.reserveCapacity(pcm.count / 2)
        var i = 0
        while i + 1 < pcm.count {
            let raw = UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8
            samples.append(Float(Int16(bitPattern: raw)) / 32768.0)
            i += 2
        }
        return WAVAudio(sampleRate: sampleRate, channels: channels, samples: samples)
    }
}