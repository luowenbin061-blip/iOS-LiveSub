// WebSocket 传输抽象 + URLSession 实现。
//
// 抽成协议是为了两件事：
//   1. 客户端循环能在无网络的单测里跑（FakeTransport）；
//   2. 将来需要时能换底层（例如 Network.framework 或带代理的实现）。
//
// 注意：URLSessionWebSocketTask 的握手是惰性的 —— connect() 立即返回，
// 连接错误会在首个 send/receive 浮出。

import Foundation

public protocol WebSocketTransport: AnyObject {
    func connect(url: String, headers: [String: String]) async throws
    func send(text: String) async throws
    /// 收到下一条文本消息；返回 nil 表示对端关闭。
    func receive() async throws -> String?
    func close() async
}

public final class URLSessionWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    public init() {
        session = URLSession(configuration: .default)
    }

    public func connect(url: String, headers: [String: String]) async throws {
        guard let u = URL(string: url) else {
            throw RealtimeError.badURL(url)
        }
        var request = URLRequest(url: u)
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
    }

    public func send(text: String) async throws {
        guard let t = task else { throw RealtimeError.notConnected }
        try await t.send(.string(text))
    }

    public func receive() async throws -> String? {
        guard let t = task else { return nil }
        let msg = try await t.receive()
        switch msg {
        case .string(let s): return s
        case .data(let d): return String(data: d, encoding: .utf8) ?? ""
        @unknown default: return ""
        }
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}