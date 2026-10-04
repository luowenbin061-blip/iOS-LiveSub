// 服务端事件 → UI 事件的归一化 —— 移植自 ReaLingo src-tauri/src/realtime.rs（MIT）。
//
// 最重要的语义：wire 协议不是增量式的 —— `text` 是截止目前已确认的全文，
// `stash` 是模型的暂定后续，两者每一帧都会重发。渲染必须「替换」，不能「追加」。

import Foundation

public struct TranslateEvent: Equatable, Sendable {
    /// source | target | speech | status | warn | error | progress | link
    public var kind: String
    public var text: String
    /// 未确认的尾巴 —— 值得显示（置灰），仍可能变化。
    public var stash: String
    /// 模型检测到的源语言（仅 transcript 事件携带）。
    public var lang: String
    /// 所属 turn。翻译事件带 assistant item 的 id；转写事件带 input item 的 id，
    /// 由 link 事件把两者对上。
    public var id: String
    public var done: Bool

    public init(kind: String,
                text: String = "",
                stash: String = "",
                lang: String = "",
                id: String = "",
                done: Bool = false) {
        self.kind = kind
        self.text = text
        self.stash = stash
        self.lang = lang
        self.id = id
        self.done = done
    }
}

public enum EventClassifier {
    /// 把一条服务端帧 JSON 归一化成事件；不认识/不该上屏的返回 nil。
    public static func classify(_ v: [String: Any]) -> TranslateEvent? {
        guard let ty = v["type"] as? String else { return nil }

        switch ty {
        case "conversation.item.created":
            // 配对 assistant item（承载译文）与它对应的 input item（承载转写）。
            // 输入项也会经由同一事件宣告，而它的 previous_item_id 指向上一轮的
            // assistant item —— 按那个配对会把每条转写错绑到上一轮。
            guard let item = v["item"] as? [String: Any] else { return nil }
            let content = item["content"] as? [[String: Any]]
            let isInput = (content?.first?["type"] as? String) == "input_audio"
            let prev = stringField(v, "previous_item_id")
            if isInput || prev.isEmpty { return nil }
            return TranslateEvent(kind: "link",
                                  text: prev,
                                  id: stringField(item, "id"))

        case "conversation.item.input_audio_transcription.text":
            return TranslateEvent(kind: "source",
                                  text: stringField(v, "text"),
                                  stash: stringField(v, "stash"),
                                  lang: stringField(v, "language"),
                                  id: stringField(v, "item_id"))

        case "conversation.item.input_audio_transcription.completed":
            return TranslateEvent(kind: "source",
                                  text: stringField(v, "transcript"),
                                  lang: stringField(v, "language"),
                                  id: stringField(v, "item_id"),
                                  done: true)

        // audio 模态下同一内容走 response.audio_transcript.* 事件名。
        case "response.text.text", "response.audio_transcript.text":
            return TranslateEvent(kind: "target",
                                  text: stringField(v, "text"),
                                  stash: stringField(v, "stash"),
                                  id: stringField(v, "item_id"))

        // audio 模态的载荷字段叫 transcript，不叫 text。
        case "response.text.done":
            return TranslateEvent(kind: "target",
                                  text: stringField(v, "text"),
                                  id: stringField(v, "item_id"),
                                  done: true)
        case "response.audio_transcript.done":
            return TranslateEvent(kind: "target",
                                  text: stringField(v, "transcript"),
                                  id: stringField(v, "item_id"),
                                  done: true)

        case "input_audio_buffer.speech_started":
            return TranslateEvent(kind: "speech", text: "start")
        case "input_audio_buffer.speech_stopped":
            return TranslateEvent(kind: "speech", text: "stop")

        case "session.created", "session.updated":
            return TranslateEvent(kind: "status", text: "connected")
        case "session.finished":
            return TranslateEvent(kind: "status", text: "closed")

        case "error":
            // 服务端 error 帧（例如 "previous turn is still processing"）不结束会话，
            // 当成致命错误会误停整个流。
            let msg = (v["error"] as? [String: Any])?["message"] as? String
                ?? v["message"] as? String
                ?? "unknown error"
            return TranslateEvent(kind: "warn", text: msg)

        default:
            return nil
        }
    }

    private static func stringField(_ v: [String: Any], _ key: String) -> String {
        (v[key] as? String) ?? ""
    }
}