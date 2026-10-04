// 测试替身与工具 —— 单测不发真实网络。

import Foundation
@testable import LiveSubCore

/// 可编程的假传输：脚本化收帧、记录发出的帧、可选连接延迟。
final class FakeTransport: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var sentFrames: [String] = []
    private var closed = false
    private var connected = false
    private(set) var lastURL: String?
    private(set) var lastHeaders: [String: String] = [:]

    /// 模拟慢连接（用于超时测试），单位：秒。
    var connectDelay: Double = 0

    func connect(url: String, headers: [String: String]) async throws {
        if connectDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000))
        }
        lock.lock()
        connected = true
        lastURL = url
        lastHeaders = headers
        lock.unlock()
    }

    func send(text: String) async throws {
        lock.lock()
        if closed {
            lock.unlock()
            throw RealtimeError.notConnected
        }
        sentFrames.append(text)
        lock.unlock()
    }

    func receive() async throws -> String? {
        while true {
            try Task.checkCancellation()
            lock.lock()
            if !inbox.isEmpty {
                let f = inbox.removeFirst()
                lock.unlock()
                return f
            }
            let isClosed = closed
            lock.unlock()
            if isClosed { return nil }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms 轮询，可取消
        }
    }

    func close() async {
        lock.lock()
        closed = true
        lock.unlock()
    }

    // MARK: 测试侧

    /// 把一条服务端帧放进收件箱。
    func push(_ frame: String) {
        lock.lock()
        inbox.append(frame)
        lock.unlock()
    }

    /// 从测试侧关闭（模拟服务端关闭）。
    func closeFromTest() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func sentSnapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentFrames
    }
}

/// 线程安全的事件收集盒（onEvent/onRawEvent 从客户端任务里回调）。
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TranslateEvent] = []
    private var raws: [[String: Any]] = []

    func append(_ e: TranslateEvent) {
        lock.lock()
        events.append(e)
        lock.unlock()
    }

    func appendRaw(_ v: [String: Any]) {
        lock.lock()
        raws.append(v)
        lock.unlock()
    }

    func eventsSnapshot() -> [TranslateEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func rawsSnapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return raws
    }
}

/// 轮询等待条件成立（默认 5 秒超时）。
@discardableResult
func waitUntil(timeout: Double = 5, _ cond: @escaping () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    return cond()
}