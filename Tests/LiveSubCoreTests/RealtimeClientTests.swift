// 客户端循环测试（新增，非上游移植）：用假传输验证编排语义。
// 覆盖：首帧顺序、append 帧编码、error 非致命、stop 收尾、未知帧分流、连接超时。

import XCTest
@testable import LiveSubCore

final class RealtimeClientTests: XCTestCase {
    private func makeClient(connectTimeout: Double = 2) -> (RealtimeClient, FakeTransport) {
        var s = Settings()
        s.apiKey = "test-key"
        s.targetLang = "zh"
        let fake = FakeTransport()
        let client = RealtimeClient(settings: s, transport: fake, connectTimeout: connectTimeout)
        return (client, fake)
    }

    func testSessionUpdateIsTheFirstFrame() async throws {
        let (client, fake) = makeClient()
        let runTask = Task { await client.run() }

        let ok = try await waitUntil { fake.sentSnapshot().count >= 1 }
        XCTAssertTrue(ok, "session.update 未发出")
        let first = fake.sentSnapshot().first ?? ""
        XCTAssertTrue(first.contains("\"session.update\""))
        XCTAssertTrue(first.contains("qwen3-asr-flash-realtime"))
        XCTAssertTrue(fake.lastHeaders["Authorization"]?.hasPrefix("Bearer ") == true)

        fake.closeFromTest()
        await runTask.value
    }

    func testPCMChunksBecomeBase64AppendFrames() async throws {
        let (client, fake) = makeClient()
        let runTask = Task { await client.run() }
        _ = try await waitUntil { fake.sentSnapshot().count >= 1 }

        client.enqueue([1, -1, 0])
        let ok = try await waitUntil { fake.sentSnapshot().count >= 2 }
        XCTAssertTrue(ok, "append 帧未发出")

        let append = fake.sentSnapshot()[1]
        let obj = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(append.utf8))) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "input_audio_buffer.append")

        let b64 = try XCTUnwrap(obj["audio"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded: b64))
        // i16 小端：1 -> 01 00；-1 -> FF FF；0 -> 00 00
        XCTAssertEqual([UInt8](bytes), [0x01, 0x00, 0xFF, 0xFF, 0x00, 0x00])

        fake.closeFromTest()
        await runTask.value
    }

    func testErrorFramesAreNonFatal() async throws {
        let (client, fake) = makeClient()
        let box = EventBox()
        client.onEvent = { box.append($0) }
        let runTask = Task { await client.run() }
        _ = try await waitUntil { fake.sentSnapshot().count >= 1 }

        fake.push(#"{"type":"error","error":{"message":"previous turn is still processing"}}"#)
        fake.push(#"{"type":"response.text.text","text":"早上好","stash":"各位"}"#)

        let ok = try await waitUntil {
            let evs = box.eventsSnapshot()
            return evs.contains { $0.kind == "warn" } && evs.contains { $0.kind == "target" }
        }
        XCTAssertTrue(ok, "warn 与 target 事件都该到达")

        let warn = box.eventsSnapshot().first { $0.kind == "warn" }
        let target = box.eventsSnapshot().first { $0.kind == "target" }
        XCTAssertEqual(warn?.text, "previous turn is still processing")
        XCTAssertEqual(target?.text, "早上好")
        XCTAssertEqual(target?.stash, "各位")

        fake.closeFromTest()
        await runTask.value
    }

    func testStopSendsSessionFinish() async throws {
        let (client, fake) = makeClient()
        let runTask = Task { await client.run() }
        _ = try await waitUntil { fake.sentSnapshot().count >= 1 }

        client.stop()
        let ok = try await waitUntil {
            fake.sentSnapshot().contains { $0.contains("session.finish") }
        }
        XCTAssertTrue(ok, "session.finish 未发出")

        fake.closeFromTest()
        await runTask.value
    }

    func testUnknownFramesReachRawHandlerOnly() async throws {
        let (client, fake) = makeClient()
        let box = EventBox()
        client.onEvent = { box.append($0) }
        client.onRawEvent = { box.appendRaw($0) }
        let runTask = Task { await client.run() }
        _ = try await waitUntil { fake.sentSnapshot().count >= 1 }

        fake.push(#"{"type":"response.output_item.added"}"#)
        _ = try await waitUntil { box.rawsSnapshot().count >= 1 }
        XCTAssertEqual(box.rawsSnapshot().count, 1)
        XCTAssertTrue(box.eventsSnapshot().filter { $0.kind != "status" }.isEmpty)

        fake.closeFromTest()
        await runTask.value
    }

    func testConnectTimeoutEmitsError() async throws {
        var s = Settings()
        s.apiKey = "k"
        let fake = FakeTransport()
        fake.connectDelay = 5
        let client = RealtimeClient(settings: s, transport: fake, connectTimeout: 0.1)
        let box = EventBox()
        client.onEvent = { box.append($0) }

        await client.run()

        let errs = box.eventsSnapshot().filter { $0.kind == "error" }
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs.first?.text.contains("timed out") == true,
                      "错误文案应说明超时，实际: \(errs.first?.text ?? "nil")")
        XCTAssertEqual(box.eventsSnapshot().last?.text, "closed")
    }
}