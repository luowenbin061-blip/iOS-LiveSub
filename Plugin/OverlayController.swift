// 悬浮层总控：把字幕、悬浮球、设置面板挂进**宿主 App 自己的窗口**。
//
// v0.3 关键决策：不自建全屏窗口赌「跨窗口触摸穿透」，直接挂进宿主窗口 ——
// 同一窗口内的 hitTest 是固定算法，空白处返回 nil 触摸自然落到宿主视图上。
// 实测确认：触摸恢复正常。
//
// v0.4：宿主会不断往自己的窗口里加内容（启动图 → 主界面、弹窗、全屏视频…），
// 这些新内容会盖住我们的容器，甚至宿主整个换窗口。所以加了 0.6s 的保温循环：
//   - 宿主换窗口 → 把容器整体搬过去
//   - 被移出层级 → 重新挂回
//   - 被新内容盖住 → 提回顶层
// 检查本身是纳秒级操作，性能可忽略；副作用是球和字幕会一直浮在宿主弹窗之上（这正是想要的）。

import UIKit

final class OverlayController {
    static let shared = OverlayController()

    private let ball = ControlBall()
    private(set) var subtitle = SubtitleView()
    private(set) var panel: SettingsPanel?
    private var root: PluginRootView?
    private var hostWindow: UIWindow?
    private var keepAlive: Timer?
    private var installed = false

    func install() {
        guard keepAlive == nil else { return }
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)  // .common：滚动/拖拽中照常跑
        keepAlive = t
        tick()
    }

    /// 保温循环：首次挂载、窗口迁移、层级保活。
    private func tick() {
        guard let host = Self.findHostWindow() else { return }

        if !installed {
            let container = PluginRootView()
            container.frame = host.bounds
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(container)
            root = container
            hostWindow = host
            installed = true
            assemble(on: container)
            return
        }

        guard let root else { return }

        if hostWindow !== host {
            // 宿主换了窗口（启动图窗口 → 主窗口之类）：整块搬过去。
            root.removeFromSuperview()
            hostWindow = host
            root.frame = host.bounds
            host.addSubview(root)
            handleGeometryChange()
            return
        }

        if root.superview !== host {
            // 被宿主移出了层级：重新挂回。
            root.removeFromSuperview()
            root.frame = host.bounds
            host.addSubview(root)
            handleGeometryChange()
        } else if host.subviews.last !== root {
            // 被宿主新加的内容盖住：提回顶层。
            host.bringSubviewToFront(root)
        }
    }

    /// 宿主窗口：优先 key + normal 层（避开 alert/键盘等系统窗口），再退而求其次。
    private static func findHostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let all = scene?.windows ?? UIApplication.shared.windows
        return all.first { $0.isKeyWindow && $0.windowLevel == .normal }
            ?? all.first { $0.windowLevel == .normal }
            ?? all.first { $0.isKeyWindow }
            ?? all.first
    }

    /// 组装控件（只在首次挂载时执行一次）。
    private func assemble(on container: PluginRootView) {
        let prefs = SettingsStore.loadUIPrefs()
        subtitle.prefs = prefs
        ball.setTitle("译", for: .normal)
        // 轻点开面板；长按解锁/锁定（长按与轻点天然不冲突，不需要双击那种等待）。
        ball.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(ballTapped)))
        ball.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(ballLongPressed(_:))))

        let panel = SettingsPanel(subtitle: subtitle)
        panel.isHidden = true

        container.subtitle = subtitle
        container.ball = ball
        container.panel = panel
        container.addSubview(subtitle)
        container.addSubview(ball)
        container.addSubview(panel)
        container.onBoundsChange = { [weak self] in self?.handleGeometryChange() }

        self.panel = panel
        layoutSubtitle(prefs: prefs)
        layoutBall(prefs: prefs)
        layoutPanel()

        // 首次使用给个上手提示（有位置记录的老用户不再打扰）。
        if prefs.subtitleCenter == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.subtitle.hint("点「译」球开面板 · 长按球解锁后可拖动/缩放字幕")
            }
        }
    }

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
            panel.refreshFromPrefs()
            panel.isHidden = false
            layoutPanel()
        } else {
            panel.isHidden = true
        }
    }

    /// 长按球：解锁/锁定字幕（解锁后才能拖动和双指缩放）。
    @objc private func ballLongPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        SettingsStore.mutatePrefs { $0.locked.toggle() }
        let prefs = SettingsStore.loadUIPrefs()
        subtitle.prefs = prefs
        panel?.refreshFromPrefs()
        subtitle.hint(prefs.locked
            ? "已锁定（点击穿透）· 长按球可解锁"
            : "已解锁：拖动换位 / 双指缩放字号 · 长按球再锁定")
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
        ver.text = "v0.5"
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