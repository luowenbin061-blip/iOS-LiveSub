// 悬浮层总控：一个高 windowLevel 的透明全屏窗口，承载字幕、悬浮球与设置面板。
// 空白区域点击穿透给宿主 App（hitTest 逻辑见文件底部的 PluginRootView）。
//
// 键盘焦点策略：平时不抢 key 窗口（宿主照常输入）；只有设置面板打开、
// 需要弹键盘时才 makeKeyAndVisible，关闭时把 key 还给原窗口。

import UIKit

final class OverlayController {
    static let shared = OverlayController()

    private var window: UIWindow?
    private let ball = ControlBall()
    private(set) var subtitle = SubtitleView()
    private(set) var panel: SettingsPanel?
    private var root: PluginRootView?
    private var installed = false
    private var previousKeyWindow: UIWindow?

    func install() {
        guard !installed else { return }
        installed = true

        // 优先挂在当前活跃的 UIWindowScene 上（iOS 13+）；没有场景时退回旧式窗口。
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let w: UIWindow
        if let scene {
            w = UIWindow(windowScene: scene)
        } else {
            w = UIWindow(frame: UIScreen.main.bounds)
        }
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear

        let root = PluginRootView()
        let vc = UIViewController()
        vc.view = root
        w.rootViewController = vc
        w.isHidden = false  // 先可见，但不抢 key

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

        self.root = root
        self.window = w
        self.panel = panel

        layoutSubtitle(prefs: prefs)
        layoutBall(prefs: prefs)
        layoutPanel()

        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleGeometryChange() }
        }
    }

    // MARK: - 对外

    func apply(_ ev: TranslateEvent) {
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
        guard let root else { return }
        layoutPanel()
        subtitle.relayout()
        ball.clampIntoSuperview()
        root.layoutIfNeeded()
    }

    // MARK: - 悬浮球

    @objc private func ballTapped() {
        guard let panel, let window else { return }
        if panel.isHidden {
            previousKeyWindow = window.windowScene?.windows.first {
                $0.isKeyWindow && $0 !== window
            }
            panel.isHidden = false
            layoutPanel()
            window.makeKeyAndVisible()  // 面板里有输入框，需要 key 才能弹键盘
        } else {
            panel.isHidden = true
            previousKeyWindow?.makeKey()
            previousKeyWindow = nil
        }
    }
}

// MARK: - 悬浮球

/// 小圆球：点击开关设置面板，拖动换位（位置持久化）。
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

/// 只有 面板 / 悬浮球 / 未锁定的字幕 接收触摸，其余区域全部穿透给宿主。
final class PluginRootView: UIView {
    weak var subtitle: SubtitleView?
    weak var ball: UIView?
    weak var panel: UIView?

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