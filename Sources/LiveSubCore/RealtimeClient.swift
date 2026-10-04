// DashScope 实时翻译 WebSocket 客户端 —— 移植自 ReaLingo src-tauri/src/realtime.rs（MIT）。
//
// 结构三段：
//   音频侧 --enqueue--> ChunkQueue(64) --上行任务--> input_audio_buffer.append 帧
//   run() 的接收循环 <-- WebSocket <-- 服务端事件（分类后回调 onEvent，原始帧回调 onRawEvent）
//
// 关键语义（全部继承上游的实证结论）：
//   - 首帧必须是 session.update；翻译目标语言会话级不可变；
//   - 事件是累积 text + 暂定 stash，渲染要替换、不要追加；
//   - 服务端 error 帧不致命，只提示；
//   - 停止后仍留 drain 窗口收翻译尾巴。

import Foundation

public enum RealtimeError: Error, LocalizedError {
    case badURL(String)
    case notConnected
    case apiKeyEmpty
    case timeout(seconds: Double)

    public var errorDescription: String? {
        switch self {
        case .badURL(let u):  return "bad url: \(u)"
        case .notConnected:   return "web socket not connected"
        case .apiKeyEmpty:    return "API key is empty"
        case .timeout(let s): return "operation timed out after \(s)s"
        }
    }
}

public final class RealtimeClient: @unchecked Sendable {
    public typealias EventHandler = (TranslateEvent) -> Void
    public typealias RawHandler = ([String: Any]) -> Void

    public var onEvent: EventHandler?
    public var onRawEvent: RawHandler?

    private let settings: Settings
    private let transport: WebSocketTransport
    private let queue: ChunkQueue
    private let connectTimeout: Double
    private let idleTimeout: Double
    private let drainTimeout: Double

    private let stateLock = NSLock()
    private var stopped = false
    private var lastActivity = Date()

    public init(settings: Settings,
                transport: WebSocketTransport = URLSessionWebSocketTransport(),
                queueCapacity: Int = 64,
                connectTimeout: Double = 15,
                idleTimeout: Double = 90,
                drainTimeout: Double = 5) {
        self.settings = settings
        self.transport = transport
        self.queue = ChunkQueue(capacity: queueCapacity)
        self.connectTimeout = connectTimeout
        self.idleTimeout = idleTimeout
        self.drainTimeout = drainTimeout
    }

    // MARK: - 对外

    /// 音频侧入口（任意线程可调）。满队丢块，永不阻塞。
    public func enqueue(_ chunk: [Int16]) {
        queue.push(chunk)
    }

    /// 请求停止：上行排空后发 session.finish；接收侧再多等 drainTimeout 收尾巴。
    public func stop() {
        markStopped()
    }

    /// 跑完整个会话：连接 → 送流 → 收事件 → 收尾。单次使用（一个实例只 run 一次）。
    public func run() async {
        emit(TranslateEvent(kind: "status", text: "connecting"))
        do {
            try await connectAndPump()
        } catch {
            emit(TranslateEvent(kind: "error", text: error.localizedDescription))
        }
        markStopped()
        emit(TranslateEvent(kind: "status", text: "closed"))
    }

    // MARK: - 内部

    private func markStopped() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        queue.close()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func touch() {
        stateLock.lock()
        lastActivity = Date()
        stateLock.unlock()
    }

    private func lastActivitySnapshot() -> Date {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastActivity
    }

    /// 停止前用长空闲窗，停止后用 drain 窗口。
    private func idleLimit() -> Double {
        isStopped ? drainTimeout : idleTimeout
    }

    private func connectAndPump() async throws {
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw RealtimeError.apiKeyEmpty }

        let url = settings.wsURL()
        let headers = ["Authorization": "Bearer \(key)"]
        let transport = self.transport
        let queue = self.queue

        try await Self.withTimeout(connectTimeout) {
            try await transport.connect(url: url, headers: headers)
        }
        // 首帧：会话配置（必须先于任何音频帧）。
        let configJSON = Self.jsonString(settings.sessionUpdate())
        try await Self.withTimeout(connectTimeout) {
            try await transport.send(text: configJSON)
        }
        emit(TranslateEvent(kind: "status", text: "connected"))
        touch()

        // 上行任务：PCM → i16 小端 → base64 → append 帧。
        let uplink = Task {
            while let chunk = await queue.pop() {
                if self.isStopped { break }  // 停止即丢剩余块（与上游一致）
                let frame = Self.appendFrame(chunk)
                do {
                    try await transport.send(text: frame)
                } catch {
                    return  // 上行坏了就退；接收侧会自行收敛
                }
            }
            _ = try? await transport.send(text: #"{"type":"session.finish"}"#)
            await transport.close()
        }

        // 空闲看门狗：到点关闭传输，让挂起的 receive 返回。
        // （不用「race 超时」是有意的：接收本身不可中断时 race 会把退出也挂住。）
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Date().timeIntervalSince(self.lastActivitySnapshot()) > self.idleLimit() {
                    await transport.close()
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        while true {
            let msg: String?
            do {
                msg = try await transport.receive()
            } catch {
                // URLSession 把对端正常关闭也报成错误；统一按「已关闭」收敛。
                emit(TranslateEvent(kind: "warn", text: "socket closed: \(error.localizedDescription)"))
                break
            }
            guard let text = msg else { break }
            touch()
            if let obj = Self.parse(text) {
                onRawEvent?(obj)
                if let ev = EventClassifier.classify(obj) {
                    emit(ev)
                }
            }
        }

        markStopped()
        await uplink.value
    }

    private func emit(_ ev: TranslateEvent) {
        onEvent?(ev)
    }

    // MARK: - 编码 / 解析

    static func appendFrame(_ chunk: [Int16]) -> String {
        var bytes = Data(capacity: chunk.count * 2)
        for s in chunk {
            let u = UInt16(bitPattern: s)
            bytes.append(UInt8(u & 0xFF))
            bytes.append(UInt8((u >> 8) & 0xFF))
        }
        return jsonString([
            "type": "input_audio_buffer.append",
            "audio": bytes.base64EncodedString(),
        ])
    }

    static func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - 超时

    /// 只用在会快速返回的操作上（连接/首帧）。
    /// 接收循环不用它 —— 见看门狗处的注释。
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw RealtimeError.timeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RealtimeError.timeout(seconds: seconds)
            }
            return first
        }
    }
}