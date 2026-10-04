// livesub-probe —— 「喂文件」调试入口：把一段 WAV 按实时节奏送进协议管线。
//
// 用法:
//   swift run livesub-probe <file.wav> --key=sk-xxx [--target=zh] [--source=auto]
//       [--model=...] [--region=beijing|singapore] [--workspace=...]
//
// 说明:
//   - 建议用 30~60 秒的短片段；没达到 16kHz 会自动重采样，超过 16kHz 也一样。
//   - 仅用于开发/验证（需要真实 API Key），CI 不跑它。
//   - 真机阶段的正式调试入口会做进插件里，这个 CLI 只是把协议层先在无真机时验通。

import Foundation
import LiveSubCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("""
    usage: livesub-probe <file.wav> --key=... [--target=zh] [--source=auto] \
    [--model=...] [--region=beijing|singapore] [--workspace=...]
    """)
}
let fileURL = URL(fileURLWithPath: args[1])

var settings = Settings()
for arg in args.dropFirst(2) {
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    switch parts[0] {
    case "--key":       settings.apiKey = parts[1]
    case "--target":    settings.targetLang = parts[1]
    case "--source":    settings.sourceLang = parts[1]
    case "--model":     settings.model = parts[1]
    case "--workspace": settings.workspaceID = parts[1]
    case "--region":    settings.region = parts[1] == "singapore" ? .singapore : .beijing
    default: break
    }
}
guard !settings.apiKey.isEmpty else { fail("missing --key") }

let audio: WAVAudio
do {
    audio = try WAVReader.read(contentsOf: fileURL)
} catch {
    fail("read wav failed: \(error.localizedDescription)")
}
FileHandle.standardError.write(Data("[probe] \(audio.sampleRate)Hz \(audio.channels)ch, \(audio.samples.count) samples\n".utf8))

let resampler = Resampler(inRate: audio.sampleRate, outRate: AudioConstants.targetRate)
let mono = downmix(audio.samples, channels: audio.channels)
let pcm = resampler.push(mono)

let client = RealtimeClient(settings: settings)
client.onEvent = { ev in
    switch ev.kind {
    case "source": print("[src \(ev.lang)] \(ev.text)\(ev.stash)")
    case "target": print("[译文] \(ev.text)\(ev.stash)")
    case "warn":   print("[warn] \(ev.text)")
    default:       print("[\(ev.kind)] \(ev.text)")
    }
}

let runTask = Task { await client.run() }

// 按实时节奏喂块（100ms/块）：VAD 行为与真实直播一致，便于对拍。
var index = 0
let chunk = AudioConstants.chunkSamples
while index < pcm.count {
    let end = min(index + chunk, pcm.count)
    client.enqueue(Array(pcm[index..<end]))
    index = end
    if (index / chunk) % 10 == 0 {
        FileHandle.standardError.write(Data(". \(index)/\(pcm.count)\n".utf8))
    }
    try await Task.sleep(nanoseconds: 100_000_000)
}

// 收尾：给翻译尾巴留 2 秒，然后停止并等会话结束。
try await Task.sleep(nanoseconds: 2_000_000_000)
client.stop()
await runTask.value
print("[probe] done")