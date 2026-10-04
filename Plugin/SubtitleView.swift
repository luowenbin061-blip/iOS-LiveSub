// 悬浮字幕（v0.7：整句模式）——按用户要求：不流式、不历史。
// 一句话完整翻译出来之后直接整句上屏，直到下一句完整翻译到来再整体替换。
// （用延迟换完整度，这是明确取舍；也顺带消掉了流式更新带来的跳动感。）
//
// 语义来源仍是协议层结论：text 累积确认 + stash 暂定 —— 但这里两者都只暂存，
// 等 done 事件（整句定稿）才真正上屏。

import UIKit

final class SubtitleView: UIView {
    var prefs: UIPrefs = UIPrefs() {
        didSet {
            applyStyle()
            render()
        }
    }

    private let mainLabel = UILabel()
    private let sourceLabel = UILabel()
    private let stack = UIStackView()

    private var currentId = ""
    /// 当前句已知的最新文本（text + stash，尚未定稿）。
    private var pendingText = ""
    /// 正在上屏的整句译文。
    private var mainText = ""
    private var sourceText = ""
    private var flashToken = 0
    private var savedMain = ""
    private var pinchBaseSize: Double = 20

    private(set) var isLocked = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func setup() {
        layer.cornerRadius = 12
        layer.masksToBounds = true

        // 压在视频上也要读得清：深色半透明底 + 文字阴影。
        for label in [mainLabel, sourceLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            label.layer.shadowOpacity = 0.9
        }

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.addArrangedSubview(mainLabel)
        stack.addArrangedSubview(sourceLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(onPan(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:))))
        applyStyle()
        render()
    }

    // MARK: - 样式

    private func applyStyle() {
        isLocked = prefs.locked
        backgroundColor = UIColor.black.withAlphaComponent(prefs.opacity)
        mainLabel.font = .boldSystemFont(ofSize: prefs.fontSize)
        mainLabel.textColor = .white
        sourceLabel.font = .systemFont(ofSize: max(prefs.fontSize - 5, 11))
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.75)
    }

    // MARK: - 事件（整句模式）

    func apply(_ ev: TranslateEvent) {
        switch ev.kind {
        case "target":
            if ev.id != currentId {
                // 上一句没等到 done 也先补上，避免整句丢失
                if !pendingText.isEmpty { show(pendingText) }
                currentId = ev.id
                pendingText = ""
            }
            if ev.done {
                show(ev.text.isEmpty ? pendingText : ev.text)
                pendingText = ""
            } else {
                pendingText = ev.text + ev.stash
            }
        case "source":
            if ev.done {
                sourceText = ev.text
                render()
            }
        case "warn", "error":
            hint(ev.text)
        default:
            break
        }
    }

    /// 整句上屏。
    private func show(_ text: String) {
        guard !text.isEmpty else { return }
        flashToken += 1  // 取消未完成的临时提示恢复
        mainText = text
        render()
    }

    /// 临时提示（错误/警告/操作反馈）：占用主行，几秒后恢复。
    func hint(_ message: String) {
        flashToken += 1
        let token = flashToken
        savedMain = mainText
        mainText = "⚠️ " + message
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.mainText = self.savedMain
            self.render()
        }
    }

    private func render() {
        mainLabel.text = mainText
        sourceLabel.text = sourceText
        sourceLabel.isHidden = !prefs.showSource || sourceText.isEmpty
        relayout()
    }

    // MARK: - 尺寸与位置

    /// 按内容自适应高度（宽度占满给定上限），保持中心不动。
    func relayout() {
        guard let sv = superview else { return }
        let maxW = min(sv.bounds.width - 24, 720)
        let fit = systemLayoutSizeFitting(
            CGSize(width: maxW, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        var f = frame
        f.size = CGSize(width: maxW, height: fit.height)
        frame = f
        clampIntoSuperview()
    }

    func clampIntoSuperview() {
        guard let sv = superview else { return }
        let halfW = bounds.width / 2, halfH = bounds.height / 2
        center.x = min(max(center.x, halfW + 8), sv.bounds.width - halfW - 8)
        center.y = min(max(center.y, halfH + 48), sv.bounds.height - halfH - 8)
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        guard !isLocked else { return }
        let t = g.translation(in: superview)
        center = CGPoint(x: center.x + t.x, y: center.y + t.y)
        g.setTranslation(.zero, in: superview)
        if g.state == .ended {
            clampIntoSuperview()
            let c = center
            SettingsStore.mutatePrefs { $0.subtitleCenter = [Double(c.x), Double(c.y)] }
        }
    }

    /// 双指缩放字号（仅解锁状态可达）。
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard !isLocked else { return }
        switch g.state {
        case .began:
            pinchBaseSize = prefs.fontSize
        case .changed:
            let size = min(max(pinchBaseSize * Double(g.scale), 12), 30)
            var p = prefs
            p.fontSize = size
            prefs = p  // didSet：样式立即生效
        case .ended, .cancelled:
            let size = prefs.fontSize
            SettingsStore.mutatePrefs { $0.fontSize = size }
        default:
            break
        }
    }
}