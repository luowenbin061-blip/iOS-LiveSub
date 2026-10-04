// 插件生命周期：等宿主 App 激活 → 装悬浮层；开始/停止协调 采集 → 协议 → 字幕。
// 入口符号 livesub_bootstrap 由 ObjC（Entry.m 的构造器）在主队列上调用。

import UIKit

@_cdecl("livesub_bootstrap")
public func livesubBootstrap() {
    Plugin.shared.installWhenActive()
}

final class Plugin {
    static let shared = Plugin()

    private let mic = MicCapture()
    private var client: RealtimeClient?
    private var installed = false
    private(set) var isRunning = false

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
        // 先挡一道，别让浏览器闪退。
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            overlay.setStatus("宿主 App 缺 NSMicrophoneUsageDescription，启用会闪退；先在浏览器工程里加上这一项")
            return
        }
        overlay.setStatus("请求麦克风权限…")
        MicCapture.ensurePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                overlay.setStatus("麦克风权限被拒 —— 到系统设置里放行后重试")
                return
            }
            self.beginSession(settings)
        }
    }

    private func beginSession(_ settings: Settings) {
        let overlay = OverlayController.shared
        let client = RealtimeClient(settings: settings)
        client.onEvent = { ev in
            DispatchQueue.main.async { overlay.apply(ev) }
        }
        self.client = client

        mic.onChunk = { [weak client] chunk in
            client?.enqueue(chunk)  // ChunkQueue 非阻塞：音频线程安全
        }
        do {
            try mic.start()
        } catch {
            overlay.setStatus("采集启动失败：\(error.localizedDescription)")
            self.client = nil
            return
        }
        isRunning = true
        overlay.setRunning(true)
        overlay.setStatus("翻译中（目标语言 \(settings.targetLang)）…")
        _ = Task { await client.run() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        mic.stop()
        client?.stop()  // 排空上行 → session.finish → 留窗口收翻译尾巴
        OverlayController.shared.setRunning(false)
        OverlayController.shared.setStatus("已停止")
    }
}