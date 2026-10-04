// 插件侧持久化：UI 偏好走 UserDefaults，API Key 走 Keychain（失败降级）。
//
// Keychain 说明：dylib 借用宿主 App 的身份访问凭据库，如果宿主缺少
// keychain-access-group 一类权限，SecItem* 会报 errSecMissingEntitlement——
// 这时静默降级回 UserDefaults，保证功能可用（设置页不为此挡路）。

import Foundation
import Security

/// 插件自己的 UI 偏好。
struct UIPrefs: Codable, Equatable {
    var fontSize: Double = 20
    var opacity: Double = 0.45
    var showSource: Bool = false
    /// 锁定 = 字幕窗点击穿透（不可拖动）。
    var locked: Bool = true
    /// [x, y]，首启为空，落默认位置。
    var subtitleCenter: [Double]?
    var ballCenter: [Double]?
    /// VAD 灵敏度：环境嘈杂、断句迟迟不闭合时调高。
    var vadThreshold: Double = 0.2
    /// VAD 静音判定（ms）。插件默认 500 比核心保守值 800 更"急"，字幕更快跟上。
    var vadSilenceMs: Int = 500
    /// 音频来源："mic"（麦克风）或 "system"（系统声音，ReplayKit 录宿主自身音频）。
    var audioSource: String = "mic"
    var targetLang: String = "zh"
    var sourceLang: String = "auto"
    var model: String = Settings.defaultModel
    var regionRAW: String = Region.beijing.rawValue
    var workspaceID: String = ""

    var region: Region { Region(rawValue: regionRAW) ?? .beijing }
}

enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let uiPrefsKey = "LiveSub.uiPrefs"
    private static let apiKeyFallbackKey = "LiveSub.apiKeyFallback"
    private static let keychainService = "LiveSub"
    private static let keychainAccount = "apiKey"

    // MARK: - UI 偏好

    static func loadUIPrefs() -> UIPrefs {
        guard let data = defaults.data(forKey: uiPrefsKey),
              let p = try? JSONDecoder().decode(UIPrefs.self, from: data) else {
            return UIPrefs()
        }
        return p
    }

    static func saveUIPrefs(_ p: UIPrefs) {
        if let data = try? JSONEncoder().encode(p) {
            defaults.set(data, forKey: uiPrefsKey)
        }
    }

    /// 读-改-写：多处写入者（面板控件 / 拖动结束）都走这里，
    /// 避免用陈旧副本覆盖别的字段。
    static func mutatePrefs(_ mutate: (inout UIPrefs) -> Void) {
        var p = loadUIPrefs()
        mutate(&p)
        saveUIPrefs(p)
    }

    /// 组装核心层 Settings（会话语义全部继承核心层默认，UI 只覆盖这几项）。
    static func loadSettings() -> Settings {
        let p = loadUIPrefs()
        var s = Settings()
        s.apiKey = loadAPIKey()
        s.targetLang = p.targetLang
        s.sourceLang = p.sourceLang
        s.model = p.model
        s.region = p.region
        s.workspaceID = p.workspaceID
        s.vadThreshold = p.vadThreshold
        s.vadSilenceMs = p.vadSilenceMs
        return s
    }

    // MARK: - API Key

    static func loadAPIKey() -> String {
        if let k = keychainLoad() { return k }
        return defaults.string(forKey: apiKeyFallbackKey) ?? ""
    }

    static func saveAPIKey(_ key: String) {
        if keychainStore(key) {
            defaults.removeObject(forKey: apiKeyFallbackKey)
        } else {
            defaults.set(key, forKey: apiKeyFallbackKey)
        }
    }

    private static func keychainLoad() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess,
              let d = out as? Data,
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private static func keychainStore(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}