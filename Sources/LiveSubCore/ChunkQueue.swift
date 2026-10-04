// 采集侧 → 上行侧的有界队列，对应 ReaLingo 里 tokio mpsc::channel(64) + try_send 的语义：
// 满队丢块、push 永不阻塞（音频线程安全）。
//
// 约定单消费者（上行任务）；并发 pop 会互相覆盖等待者。

import Foundation

public final class ChunkQueue {
    public typealias Chunk = [Int16]

    private let lock = NSLock()
    private var buffer: [Chunk] = []
    private var closed = false
    private let capacity: Int
    private var waiter: CheckedContinuation<Chunk?, Never>?

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    /// 满时直接丢弃这个块（与上游 try_send 失败即丢的行为一致），绝不阻塞调用方。
    public func push(_ chunk: Chunk) {
        lock.lock()
        if closed || buffer.count >= capacity {
            lock.unlock()
            return
        }
        buffer.append(chunk)
        if let w = waiter {
            waiter = nil
            let next = buffer.removeFirst()
            lock.unlock()
            w.resume(returning: next)
            return
        }
        lock.unlock()
    }

    /// 取下一块；队列关闭且已取空后返回 nil。
    public func pop() async -> Chunk? {
        lock.lock()
        if !buffer.isEmpty {
            let c = buffer.removeFirst()
            lock.unlock()
            return c
        }
        if closed {
            lock.unlock()
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Chunk?, Never>) in
            waiter = cont
            lock.unlock()
        }
    }

    /// 关闭：唤醒等待者（得 nil）；之后 push 一律丢弃。
    public func close() {
        lock.lock()
        closed = true
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: nil)
            return
        }
        lock.unlock()
    }
}