// 悬浮层总控：把字幕、悬浮球、设置面板挂进**宿主 App 自己的窗口**。
//
// v0.3 关键决策：不再自建全屏窗口赌「跨窗口触摸穿透」，而是直接挂进宿主窗口。
// 理由：同一窗口内的 hitTest 是固定算法 —— 我们的容器在空白处返回 nil，
// 触摸就自然落到宿主自己的视图上；不存在跨窗口投递的变数。
// （找不到宿主窗口时才退回自建穿透窗口的旧路径。）
//
// 键盘：面板挂在宿主窗口里，点输入框时宿主窗口本就是 key，键盘正常弹出。

import UIKit

final class OverlayController {
    static let shared = OverlayController()

    /// 自建窗口模式下的窗口（挂宿主窗口成功时为空）。
    private var ownWindow: UIWindow?
    private var ownWindowPreviousKey: UIWindow?
    /// 宿主窗口（挂载模式）。
    private var hostWindow: UIWindow?

    private let ball = ControlBall()
    private(set) var subtitle = SubtitleView()
    private(set) var panel: SettingsPanel?
    private var root: PluginRootView?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true

        if let host = Self.findHostWindow(), let hostRoot = attachToHost(host) {
            hostWindow = host
            root = hostRoot
        } else if let (window, ownRoot) = makeOwnWindow() {
            ownWindow = window
            root = ownRoot
        } else {
            return
        }

        guard let root else { return }

        let prefs = SettingsStore.loadUIPrefs()
        subtitle.prefs = prefs
        ball.setTitle("译", for: .normal)
        ball.addTarget(self, action: #selector(ballTapped), for: .touchUpInside)

        let panel = SettingsPanel(subtitle: subtitle)
        panel.isHidden = true

        root.subtitle = subtitle
        root.ball = ball
        root.panel = panel
        root.addSubview(subtitle)
        root.addSubview(ball)
        root.addSubview(panel)
        root.onBoundsChange = { [weak self] in self?.handleGeometryChange() }

        self.panel = panel

        layoutSubtitle(prefs: prefs)
        layoutBall(prefs: prefs)
        layoutPanel()
    }

    // MARK: - 挂载

    /// 找宿主 App 自己的窗口：优先 key，其次 .normal 层，最后任意非本插件窗口。
    private static func findHostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let all = scene?.windows ?? UIApplication.shared.windows
        let candidates = all.filter { !($0 is PassthroughWindow) }
        return candidates.first { $0.isKeyWindow }
            ?? candidates.first { $0.windowLevel == .normal }
            ?? candidates.first
    }

    /// 把穿透容器作为宿主窗口的顶层子视图挂进去。
    private func attachToHost(_ host: UIWindow) -> PluginRootView? {
        let root = PluginRootView()
        root.frame = host.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(root)
        return root
    }

    /// 兜底：没找到宿主窗口时，自建一个穿透窗口（保留旧路径）。
    private func makeOwnWindow() -> (UIWindow, PluginRootView)? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let w: UIWindow
        if let scene {
            w = PassthroughWindow(windowScene: scene)
        } else {
            w = PassthroughWindow(frame: UIScreen.main.bounds)
        }
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear
        let root = PluginRootView()
        let vc = UIViewController()
        vc.view = root
        w.rootViewController = vc
        w.isHidden = false
        return (w, root)
    }

    /// 挂宿主窗口时，宿主后续弹的全屏内容可能压住我们 —— 字幕流动时顺手把容器提回顶层。
    private func ensureOnTop() {
        guard let root, let host = hostWindow, root.superview === host else { return }
        if host.subviews.last !== root {
            host.bringSubviewToFront(root)
        }
    }

    // MARK: - 对外

    func apply(_ ev: TranslateEvent) {
        ensureOnTop()
        subtitle.apply(ev)
    }

    func setStatus(_ text: String) {
        panel?.setStatus(text)
    }

    func setRunning(_ running: Bool) {
        panel?.setRunning(running)
        ball.backgroundColor = (running ? UIColor.systemGreen : UIColor.systemBlue)
            .withAlphaComponent(0.85)
    }

    // MARK: - 布局

    private func layoutSubtitle(prefs: UIPrefs) {
        guard let root else { return }
        let width = min(root.bounds.width - 24, 720)
        let fit = subtitle.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        subtitle.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: fit.height))
        if let c = prefs.subtitleCenter, c.count == 2 {
            subtitle.center = CGPoint(x: c[0], y: c[1])
        } else {
            subtitle.center = CGPoint(x: root.bounds.midX, y: root.bounds.height - 200)
        }
        subtitle.clampIntoSuperview()
    }

    private func layoutBall(prefs: UIPrefs) {
        guard let root else { return }
        if let c = prefs.ballCenter, c.count == 2 {
            ball.center = CGPoint(x: c[0], y: c[1])
        } else {
            ball.center = CGPoint(x: root.bounds.width - 44, y: root.bounds.height - 140)
        }
        ball.clampIntoSuperview()
    }

    private func layoutPanel() {
        guard let root, let panel else { return }
        let width = min(root.bounds.width - 32, 420)
        let fit = panel.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        panel.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: fit.height))
        // 顶部锚定，键盘弹起也盖不住输入框。
        panel.center = CGPoint(x: root.bounds.midX, y: 60 + fit.height / 2)
    }

    private func handleGeometryChange() {
        layoutPanel()
        subtitle.relayout()
        ball.clampIntoSuperview()
    }

    // MARK: - 悬浮球

    @objc private func ballTapped() {
        guard let panel else { return }
        if panel.isHidden {
            ensureOnTop()
            panel.isHidden = false
            layoutPanel()
            if let own = ownWindow {
                // 只有自建窗口模式需要抢 key 才能弹键盘；挂宿主窗口时宿主本就是 key。
                ownWindowPreviousKey = own.windowScene?.windows.first {
                    $0.isKeyWindow && $0 !== own
                }
                own.makeKeyAndVisible()
            }
        } else {
            panel.isHidden = true
            ownWindowPreviousKey?.makeKey()
            ownWindowPreviousKey = nil
        }
    }
}

// MARK: - 悬浮球

/// 小圆球：点击开关设置面板，拖动换位（位置持久化）。球上有版本小字，便于无触摸核对当前注入的包。
final class ControlBall: UIButton {
    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        setTitleColor(.white, for: .normal)
        titleLabel?.font = .boldSystemFont(ofSize: 18)
        layer.cornerRadius = 26
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 6
        layer.shadowOffset = .zero
        // 拖动开始会取消按钮的 touchUpInside；轻点仍照常触发。
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onPan(_:))))

        // 版本小字：不用触摸就能确认手机上跑的是哪一版。
        let ver = UILabel()
        ver.text = "v0.3"
        ver.font = .systemFont(ofSize: 8)
        ver.textColor = UIColor.white.withAlphaComponent(0.9)
        ver.textAlignment = .center
        ver.isUserInteractionEnabled = false
        ver.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ver)
        NSLayoutConstraint.activate([
            ver.centerXAnchor.constraint(equalTo: centerXAnchor),
            ver.topAnchor.constraint(equalTo: centerYAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func clampIntoSuperview() {
        guard let sv = superview else { return }
        let half = bounds.width / 2
        center.x = min(max(center.x, half + 6), sv.bounds.width - half - 6)
        center.y = min(max(center.y, half + 48), sv.bounds.height - half - 6)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: superview)
        if g.state == .ended {
            clampIntoSuperview()
            let c = center
            SettingsStore.mutatePrefs { $0.ballCenter = [Double(c.x), Double(c.y)] }
        }
    }
}

// MARK: - 穿透根视图

/// 只有 面板 / 悬浮球 / 未锁定的字幕 接收触摸，其余区域全部穿透。
/// 挂进宿主窗口后，「返回 nil → 触摸落到宿主视图」是同一窗口内的固定 hitTest 算法。
final class PluginRootView: UIView {
    weak var subtitle: SubtitleView?
    weak var ball: UIView?
    weak var panel: UIView?

    /// 尺寸变化（旋转等）时通知外部重新布局。
    var onBoundsChange: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onBoundsChange?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let panel, !panel.isHidden, panel.frame.contains(point) {
            return panel.hitTest(convert(point, to: panel), with: event)
        }
        if let ball, !ball.isHidden, ball.frame.contains(point) {
            return ball.hitTest(convert(point, to: ball), with: event)
        }
        if let subtitle, !subtitle.isHidden, !subtitle.isLocked,
           subtitle.frame.contains(point) {
            return subtitle.hitTest(convert(point, to: subtitle), with: event)
        }
        return nil  // 其余区域点击穿透
    }
}

// MARK: - 穿透窗口（仅自建窗口兜底路径使用）

/// 兜底路径的窗口：hitTest 在没命中真实控件时返回 nil，让触摸继续投递。
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self { return nil }
        if let root = rootViewController?.view, hit === root { return nil }
        return hit
    }
}