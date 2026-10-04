// 设置面板：卡片式，所有控件即时保存（读-改-写，避免互相覆盖）。
// 开始/停止走 Plugin 注入的闭包；状态文本由 Plugin / OverlayController 推送。

import UIKit

final class SettingsPanel: UIView, UITextFieldDelegate {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private unowned let subtitle: SubtitleView
    private var prefs: UIPrefs

    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let apiField = UITextField()
    private let targetField = UITextField()
    private let modelSeg = UISegmentedControl(items: ["60 语种", "18 语种"])
    private let regionSeg = UISegmentedControl(items: ["北京", "新加坡"])
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let sourceSwitch = UISwitch()
    private let lockSwitch = UISwitch()
    private var running = false

    init(subtitle: SubtitleView) {
        self.subtitle = subtitle
        self.prefs = SettingsStore.loadUIPrefs()
        super.init(frame: .zero)
        setup()
        loadFromPrefs()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - 搭建

    private func setup() {
        backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.96)
        layer.cornerRadius = 16
        layer.masksToBounds = true

        let title = UILabel()
        title.text = "LiveSub 实时字幕"
        title.font = .boldSystemFont(ofSize: 16)
        title.textColor = .white

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        statusLabel.numberOfLines = 0
        statusLabel.text = "未启动（v0.2）"

        startButton.setTitle("开始翻译", for: .normal)
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 15)
        startButton.setTitleColor(.systemGreen, for: .normal)
        startButton.addTarget(self, action: #selector(toggleRunning), for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("收起面板", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 13)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        apiField.placeholder = "百炼 API Key"
        apiField.isSecureTextEntry = true
        apiField.borderStyle = .roundedRect
        apiField.autocapitalizationType = .none
        apiField.autocorrectionType = .no
        apiField.returnKeyType = .done
        apiField.delegate = self
        apiField.addTarget(self, action: #selector(apiChanged), for: .editingDidEnd)

        targetField.placeholder = "目标语言（zh / en / ja…）"
        targetField.borderStyle = .roundedRect
        targetField.autocapitalizationType = .none
        targetField.autocorrectionType = .no
        targetField.returnKeyType = .done
        targetField.delegate = self
        targetField.addTarget(self, action: #selector(targetChanged), for: .editingDidEnd)

        modelSeg.addTarget(self, action: #selector(modelChanged), for: .valueChanged)
        regionSeg.addTarget(self, action: #selector(regionChanged), for: .valueChanged)

        sizeSlider.minimumValue = 12
        sizeSlider.maximumValue = 30
        sizeSlider.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        opacitySlider.minimumValue = 0
        opacitySlider.maximumValue = 1
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)

        sourceSwitch.addTarget(self, action: #selector(sourceChanged), for: .valueChanged)
        lockSwitch.addTarget(self, action: #selector(lockChanged), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [
            title,
            statusLabel,
            startButton,
            labeled("API Key", apiField),
            labeled("目标语言", targetField),
            labeled("模型", modelSeg),
            labeled("地域", regionSeg),
            labeled("字幕字号", sizeSlider),
            labeled("背景透明度", opacitySlider),
            switchRow("显示原文（双语）", sourceSwitch),
            switchRow("锁定字幕（点击穿透）", lockSwitch),
            closeButton,
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    private func labeled(_ text: String, _ control: UIView) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12)
        l.textColor = UIColor.white.withAlphaComponent(0.65)
        l.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [l, control])
        row.axis = .horizontal
        row.spacing = 8
        return row
    }

    private func switchRow(_ text: String, _ sw: UISwitch) -> UIView {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 12)
        l.textColor = UIColor.white.withAlphaComponent(0.65)
        let row = UIStackView(arrangedSubviews: [l, sw])
        row.axis = .horizontal
        row.spacing = 8
        return row
    }

    private func loadFromPrefs() {
        apiField.text = SettingsStore.loadAPIKey()
        targetField.text = prefs.targetLang
        modelSeg.selectedSegmentIndex = prefs.model == Settings.legacyModel ? 1 : 0
        regionSeg.selectedSegmentIndex = prefs.region == .singapore ? 1 : 0
        sizeSlider.value = Float(prefs.fontSize)
        opacitySlider.value = Float(prefs.opacity)
        sourceSwitch.isOn = prefs.showSource
        lockSwitch.isOn = prefs.locked
    }

    /// 读-改-写提交，随后同步到字幕层（不动拖动保存的位置字段）。
    private func commit(_ change: (inout UIPrefs) -> Void) {
        SettingsStore.mutatePrefs(change)
        prefs = SettingsStore.loadUIPrefs()
        subtitle.prefs = prefs
    }

    // MARK: - 动作

    @objc private func toggleRunning() {
        if running { onStop?() } else { onStart?() }
    }

    @objc private func apiChanged() {
        SettingsStore.saveAPIKey(apiField.text ?? "")
    }

    @objc private func targetChanged() {
        let t = (targetField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        commit { $0.targetLang = t.isEmpty ? "zh" : t }
        targetField.text = prefs.targetLang
    }

    @objc private func modelChanged() {
        commit { $0.model = modelSeg.selectedSegmentIndex == 1 ? Settings.legacyModel : Settings.defaultModel }
    }

    @objc private func regionChanged() {
        let raw = (regionSeg.selectedSegmentIndex == 1 ? Region.singapore : Region.beijing).rawValue
        commit { $0.regionRAW = raw }
    }

    @objc private func sizeChanged() {
        commit { $0.fontSize = Double(sizeSlider.value) }
    }

    @objc private func opacityChanged() {
        commit { $0.opacity = Double(opacitySlider.value) }
    }

    @objc private func sourceChanged() {
        commit { $0.showSource = sourceSwitch.isOn }
    }

    @objc private func lockChanged() {
        commit { $0.locked = lockSwitch.isOn }
    }

    @objc private func closeTapped() {
        isHidden = true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - 状态

    func setStatus(_ text: String) {
        statusLabel.text = text
    }

    func setRunning(_ r: Bool) {
        running = r
        startButton.setTitle(r ? "停止翻译" : "开始翻译", for: .normal)
        startButton.setTitleColor(r ? .systemRed : .systemGreen, for: .normal)
    }
}