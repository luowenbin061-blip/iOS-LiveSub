// 会话设置 —— 移植自 ReaLingo src-tauri/src/config.rs（MIT）。
// 语义与默认值保持与上游一致；UI 层再按需改目标语言等。

import Foundation

public enum Region: String, Codable, Sendable {
    case beijing
    case singapore
}

public struct Settings: Codable, Equatable, Sendable {
    /// 当前主模型（60 语种）。
    public static let defaultModel = "qwen3.5-livetranslate-flash-realtime"
    /// 上一代模型：同协议，但只支持 18 语种。
    public static let legacyModel = "qwen3-livetranslate-flash-realtime"
    /// 语音识别模型，随会话下发。
    public static let asrModel = "qwen3-asr-flash-realtime"

    public var apiKey: String = ""
    /// 选填。留空走公共域名；填写后走业务空间专属域名（性能更好）。
    public var workspaceID: String = ""
    public var region: Region = .beijing
    /// "auto" = 省略 language 字段，由模型自动检测源语言。
    public var sourceLang: String = "auto"
    public var targetLang: String = "en"
    public var model: String = Settings.defaultModel
    /// 热词：源词 -> 译文。服务端上限 1000 条。
    public var hotwords: [String: String] = [:]

    public init() {}

    /// 最终连接的 WebSocket 地址（设置页可以直接展示它，便于排障）。
    public func wsURL() -> String {
        let ws = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        switch (region, ws.isEmpty) {
        case (.beijing, true):    host = "dashscope.aliyuncs.com"
        case (.beijing, false):   host = "\(ws).cn-beijing.maas.aliyuncs.com"
        case (.singapore, true):  host = "dashscope-intl.aliyuncs.com"
        case (.singapore, false): host = "\(ws).ap-southeast-1.maas.aliyuncs.com"
        }
        let m = model.isEmpty ? Settings.defaultModel : model
        return "wss://\(host)/api-ws/v1/realtime?model=\(m)"
    }

    /// `session.update` 载荷。只开文本模态：我们要的是字幕，不是语音。
    public func sessionUpdate() -> [String: Any] {
        var transcription: [String: Any] = ["model": Settings.asrModel]
        // 省略 language 才是「自动检测源语言」的语义。
        if sourceLang != "auto" && !sourceLang.isEmpty {
            transcription["language"] = sourceLang
        }

        var translation: [String: Any] = ["language": targetLang]
        // 空 corpus 不是文档化的形状，不发。
        if !hotwords.isEmpty {
            translation["corpus"] = ["phrases": hotwords]
        }

        return [
            "type": "session.update",
            "session": [
                "modalities": ["text"],
                "input_audio_format": "pcm",
                // 会话级不可变：对已开始的会话再发 session.update 会被拒且服务端直接断连
                // （ReaLingo 用真实端点验证过）。双向互译需要两条并行会话。
                "translation": translation,
                "input_audio_transcription": transcription,
                // 不显式配置 VAD 的话服务端永远不会结束一个 turn，文本会累积成一整段。
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.2,
                    "silence_duration_ms": 800,
                ],
            ],
        ]
    }
}