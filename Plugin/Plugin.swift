// 插件生命周期：等宿主 App 激活 → 装悬浮层；开始/停止协调 采集 → 协议 → 字幕。
// 入口符号 livesub_bootstrap 由 ObjC（Entry.m 的构造器）在主队列上调用。
//
// v0.7：采集源可选 —— 麦克风 / 系统声音（ReplayKit 录宿主自身音频流）。
//   - 面板「音频来源」切换，停止再开始生效
//   - 会话自愈沿用 v0.6：socket 断自动重连（封顶 5 次）、采集停产自动拉回、球色即状态

import UIKit

@_cdecl("livesub_bootstrap")
public func livesubBootstrap() {
    Plugin.shared.installWhenActive()
}

final class Plugin {
    static let shared = Plugin()

    private let mic = MicCapture()
    private let system = SystemCapture()
    /// 当前生效的采集源（麦克风 / 系统声音 二选一）。
    private var capture: AudioCapturing?
    private var client: RealtimeClient?
    private var sessionTask: Task<Void, Never>?
    private var installed = false
    private(set) var isRunning = false
    private var reconnectAttempts = 0
    private var lastEventAt = Date()
    private var healthTimer: Timer?

    func installWhenActive() {
        guard !installed else { return }
        if UIApplication.shared.applicationState == .active {
            install()
        } else {
            // 加载发生在启动早期：等激活通知再装 UI。
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.install()
            }
        }
    }

    private func install() {
        guard !installed else { return }
        installed = true
        let overlay = OverlayController.shared
        overlay.install()
        overlay.panel?.onStart = { [weak self] in self?.start() }
        overlay.panel?.onStop = { [weak self] in self?.stop() }
    }

    // MARK: - 开始 / 停止

    func start() {
        guard !isRunning else { return }
        let overlay = OverlayController.shared
        let settings = SettingsStore.loadSettings()
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            overlay.setStatus("先在面板里填百炼 API Key")
            return
        }
        // 宿主 Info.plist 缺麦克风权限描述时，系统会在第一次访问麦克风时直接杀掉 App。
        // 麦克风来源才需要这道闸；系统声音来源走录屏授权，不碰它。
        let useSystem = SettingsStore.loadUIPrefs().audioSource == "system"
        if !useSystem, Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
            overlay.setStatus("宿主 App 缺 NSMicrophoneUsageDescription，启用会闪退；先在浏览器工程里加上这一项")
            return
        }
        if useSystem {
            self.reconnectAttempts = 0
            self.beginSession(settings)
            return
        }
        overlay.setStatus("请求麦克风权限…")
        MicCapture.ensurePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                overlay.setStatus("麦克风权限被拒 —— 到系统设置里放行后重试")
                return
            }
            self.reconnectAttempts = 0
            self.beginSession(settings)
        }
    }

    private func beginSession(_ settings: Settings) {
        let overlay = OverlayController.shared
        let prefs = SettingsStore.loadUIPrefs()
        let desired: AudioCapturing = (prefs.audioSource == "system") ? system : mic

        // 采集源切换（或首次启用）：换源时停掉旧的。
        if capture !== desired {
            capture?.stop()
            capture = desired
            wire(desired)
        }
        if let c = capture, !c.running {
            do {
                try c.start()
            } catch {
                overlay.setStatus("采集启动失败：\(error.localizedDescription)")
                capture = nil
                return
            }
        }

        let client = RealtimeClient(settings: settings)
        client.onEvent = { [weak self] ev in
            DispatchQueue.main.async {
                self?.lastEventAt = Date()
                self?.reconnectAttempts = 0
                OverlayController.shared.apply(ev)
            }
        }
        self.client = client
        isRunning = true
        lastEventAt = Date()
        startHealthTimer()
        overlay.setRunning(true)
        overlay.setStatus("翻译中（\(prefs.audioSource == "system" ? "系统声音" : "麦克风") → \(settings.targetLang)）…")
        sessionTask = Task { [weak self] in
            await client.run()
            DispatchQueue.main.async { self?.sessionLoopEnded() }
        }
    }

    /// 采集源回调接线（每个采集源只接一次）。
    private func wire(_ c: AudioCapturing) {
        c.onChunk = { [weak self] chunk in
            self?.client?.enqueue(chunk)  // ChunkQueue 非阻塞：采集线程安全
        }
        c.onInterrupted = {
            OverlayController.shared.setStatus("采集中断（检查录屏授权），正在尝试恢复…")
            OverlayController.shared.setBallState(.reconnecting)
        }
        c.onRecovered = {
            OverlayController.shared.setStatus("采集已恢复")
            OverlayController.shared.setBallState(.running)
        }
    }

    /// 会话循环结束（socket 关闭/空闲超时/报错）：用户没喊停 → 自动重连。
    private func sessionLoopEnded() {
        guard isRunning else { return }
        client = nil
        reconnectAttempts += 1
        let overlay = OverlayController.shared
        if reconnectAttempts > 5 {
            isRunning = false
            stopHealthTimer()
            overlay.setRunning(false)
            overlay.setStatus("连续 5 次重连失败，已停止；检查网络 / API Key 后重开")
            return
        }
        overlay.setBallState(.reconnecting)
        overlay.setStatus("会话断开，3 秒后自动重连（第 \(reconnectAttempts) 次）…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isRunning else { return }
            self.beginSession(SettingsStore.loadSettings())
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        reconnectAttempts = 0
        stopHealthTimer()
        capture?.stop()
        capture = nil
        client?.stop()
        client = nil
        OverlayController.shared.setRunning(false)
        OverlayController.shared.setStatus("已停止")
    }

    // MARK: - 健康巡查

    private func startHealthTimer() {
        stopHealthTimer()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func healthCheck() {
        guard isRunning else { return }
        capture?.ensureRunning()
        if Date().timeIntervalSince(lastEventAt) > 75 {
            OverlayController.shared.setStatus("已超过 1 分钟没有翻译输出；若确有声音在放，建议停止再开始")
        }
    }
}