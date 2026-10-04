// 悬浮字幕：最近一句（灰小）+ 当前句（大，暂定尾巴置灰）+ 可选原文行。
//
// 渲染语义继承协议层结论：text 是累积确认文本、stash 是暂定尾巴 —— 每次都整体替换，
// 不做追加。turn 切换（id 变化）时才把上一句推进历史行。

import UIKit

final class SubtitleView: UIView {
    var prefs: UIPrefs = UIPrefs() {
        didSet {
            applyStyle()
            render()
        }
    }

    private let historyLabel = UILabel()
    private let mainLabel = UILabel()
    private let sourceLabel = UILabel()
    private let stack = UIStackView()

    private var history: [String] = []
    private var currentId = ""
    private var currentText = ""
    private var currentStash = ""
    private var currentSource = ""
    private var flashToken = 0

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
        for label in [historyLabel, mainLabel, sourceLabel] {
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
        stack.addArrangedSubview(historyLabel)
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
        applyStyle()
        render()
    }

    // MARK: - 样式

    private func applyStyle() {
        isLocked = prefs.locked
        backgroundColor = UIColor.black.withAlphaComponent(prefs.opacity)
        mainLabel.font = .boldSystemFont(ofSize: prefs.fontSize)
        mainLabel.textColor = .white
        historyLabel.font = .systemFont(ofSize: max(prefs.fontSize - 6, 10))
        historyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        sourceLabel.font = .systemFont(ofSize: max(prefs.fontSize - 5, 11))
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.75)
    }

    // MARK: - 事件

    func apply(_ ev: TranslateEvent) {
        switch ev.kind {
        case "target":
            if ev.id != currentId {
                if !currentText.isEmpty { pushHistory(currentText) }
                currentId = ev.id
                currentText = ""
                currentStash = ""
            }
            currentText = ev.text
            currentStash = ev.done ? "" : ev.stash
            render()
        case "source":
            currentSource = ev.text + (ev.done ? "" : ev.stash)
            render()
        case "warn", "error":
            flash(ev.text)
        default:
            break
        }
    }

    private func pushHistory(_ line: String) {
        history.append(line)
        if history.count > 1 { history.removeFirst(history.count - 1) }
    }

    private func render() {
        mainLabel.attributedText = Self.attributed(text: currentText, stash: currentStash)
        historyLabel.text = history.last
        historyLabel.isHidden = history.isEmpty
        sourceLabel.text = currentSource
        sourceLabel.isHidden = !prefs.showSource || currentSource.isEmpty
        relayout()
    }

    /// 短暂顶替历史行显示提示（错误/警告），几秒后恢复。
    private func flash(_ message: String) {
        flashToken += 1
        let token = flashToken
        let saved = history
        history = ["⚠️ " + message]
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.flashToken == token else { return }
            self.history = saved
            self.render()
        }
    }

    private static func attributed(text: String, stash: String) -> NSAttributedString {
        let a = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: UIColor.white,
        ])
        if !stash.isEmpty {
            a.append(NSAttributedString(string: text.isEmpty ? stash : " " + stash, attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(0.45),
            ]))
        }
        return a
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
}