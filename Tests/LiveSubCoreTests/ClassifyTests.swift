// 移植自 ReaLingo src-tauri/src/realtime.rs 的 8 个单测（MIT）：
// 全部使用从真实端点抓回并写进上游测试的帧形状。

import XCTest
@testable import LiveSubCore

final class ClassifyTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        guard let d = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            XCTFail("bad json fixture: \(s)")
            return [:]
        }
        return obj
    }

    func testTranslationTextIsCumulativePlusATentativeStash() {
        let ev = EventClassifier.classify(json(
            #"{"type":"response.text.text","text":"早上好，各位。","stash":"欢迎来到季度"}"#))
        XCTAssertEqual(ev?.kind, "target")
        XCTAssertEqual(ev?.text, "早上好，各位。")
        XCTAssertEqual(ev?.stash, "欢迎来到季度")
        XCTAssertEqual(ev?.done, false)
    }

    func testEmptyConfirmedTextStillReachesTheUI() {
        // turn 的最初几帧什么都还没确认；渲染成空串是正确的。
        let ev = EventClassifier.classify(json(
            #"{"type":"response.text.text","text":"","stash":"早上好"}"#))
        XCTAssertEqual(ev?.text, "")
        XCTAssertEqual(ev?.stash, "早上好")
    }

    func testDoneCarriesTheWholeSentence() {
        let ev = EventClassifier.classify(json(
            #"{"type":"response.text.done","text":"早上好，各位。"}"#))
        XCTAssertEqual(ev?.done, true)
        XCTAssertEqual(ev?.text, "早上好，各位。")
        XCTAssertEqual(ev?.stash, "")
    }

    func testTranscriptCompletedReadsTheTranscriptFieldAndLanguage() {
        let ev = EventClassifier.classify(json(
            #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Good morning, everyone.","language":"en"}"#))
        XCTAssertEqual(ev?.kind, "source")
        XCTAssertEqual(ev?.text, "Good morning, everyone.")
        XCTAssertEqual(ev?.lang, "en")
        XCTAssertEqual(ev?.done, true)
    }

    func testAssistantItemLinksToTheInputItemItAnswers() {
        let ev = EventClassifier.classify(json(
            #"{"type":"conversation.item.created","item":{"id":"item_assistant","content":[],"role":"assistant"},"previous_item_id":"item_input"}"#))
        XCTAssertEqual(ev?.kind, "link")
        XCTAssertEqual(ev?.id, "item_assistant")
        XCTAssertEqual(ev?.text, "item_input")
    }

    func testTheInputItemsOwnAnnouncementIsNotALink() {
        // 输入项的 previous_item_id 指向上一轮的 assistant item，
        // 取它会把每条转写错绑到上一轮。
        let ev = EventClassifier.classify(json(
            #"{"type":"conversation.item.created","item":{"id":"item_input","content":[{"type":"input_audio"}]},"previous_item_id":"item_assistant_of_previous_turn"}"#))
        XCTAssertNil(ev)
    }

    func testTurnIdsRideAlongWithTranscriptsAndTranslations() {
        let src = EventClassifier.classify(json(
            #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item_input","transcript":"Good morning."}"#))
        XCTAssertEqual(src?.id, "item_input")

        let tgt = EventClassifier.classify(json(
            #"{"type":"response.text.done","item_id":"item_assistant","text":"早上好。"}"#))
        XCTAssertEqual(tgt?.id, "item_assistant")
    }

    func testUnknownEventsAreIgnored() {
        XCTAssertNil(EventClassifier.classify(json(#"{"type":"response.output_item.added"}"#)))
        XCTAssertNil(EventClassifier.classify(json(#"{"no_type":1}"#)))
    }
}