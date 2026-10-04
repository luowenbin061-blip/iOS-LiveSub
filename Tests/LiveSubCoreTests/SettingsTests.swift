// 移植自 ReaLingo src-tauri/src/config.rs 的 8 个单测（MIT）。

import XCTest
@testable import LiveSubCore

final class SettingsTests: XCTestCase {
    private func make(region: Region = .beijing, workspace: String = "") -> Settings {
        var s = Settings()
        s.apiKey = "k"
        s.workspaceID = workspace
        s.region = region
        s.sourceLang = "auto"
        s.targetLang = "en"
        s.model = Settings.defaultModel
        return s
    }

    func testURLFallsBackToPublicDomainWithoutWorkspace() {
        XCTAssertTrue(make(workspace: "  ").wsURL().hasPrefix("wss://dashscope.aliyuncs.com/"))
        XCTAssertTrue(make(region: .singapore, workspace: "").wsURL()
            .hasPrefix("wss://dashscope-intl.aliyuncs.com/"))
    }

    func testURLUsesDedicatedDomainWithWorkspace() {
        XCTAssertTrue(make(workspace: "llm-abc").wsURL()
            .hasPrefix("wss://llm-abc.cn-beijing.maas.aliyuncs.com/"))
        XCTAssertTrue(make(region: .singapore, workspace: "llm-abc").wsURL()
            .hasPrefix("wss://llm-abc.ap-southeast-1.maas.aliyuncs.com/"))
    }

    func testURLCarriesTheSelectedModel() {
        XCTAssertTrue(make().wsURL().hasSuffix("?model=\(Settings.defaultModel)"))
        var legacy = make()
        legacy.model = Settings.legacyModel
        XCTAssertTrue(legacy.wsURL().hasSuffix("?model=\(Settings.legacyModel)"))
    }

    func testEmptyModelFallsBackToTheCurrentOne() {
        var blank = make()
        blank.model = ""
        XCTAssertTrue(blank.wsURL().hasSuffix("?model=\(Settings.defaultModel)"))
    }

    func testTurnDetectionIsConfiguredNotEmpty() {
        let session = make().sessionUpdate()["session"] as? [String: Any]
        let vad = session?["turn_detection"] as? [String: Any]
        XCTAssertEqual(vad?["type"] as? String, "server_vad")
        let silence = (vad?["silence_duration_ms"] as? Int) ?? 0
        XCTAssertGreaterThan(silence, 0)
    }

    func testNoHotwordsOmitsCorpus() {
        let session = make().sessionUpdate()["session"] as? [String: Any]
        let translation = session?["translation"] as? [String: Any]
        XCTAssertEqual(translation?["language"] as? String, "en")
        XCTAssertNil(translation?["corpus"])
    }

    func testHotwordsGoUnderTranslationCorpusPhrases() {
        var with = make()
        with.hotwords = ["人工智能": "Artificial Intelligence"]
        let session = with.sessionUpdate()["session"] as? [String: Any]
        let translation = session?["translation"] as? [String: Any]
        let corpus = translation?["corpus"] as? [String: Any]
        let phrases = corpus?["phrases"] as? [String: String]
        XCTAssertEqual(phrases?["人工智能"], "Artificial Intelligence")
    }

    func testAutoSourceOmitsLanguageField() {
        let session = make().sessionUpdate()["session"] as? [String: Any]
        let transcription = session?["input_audio_transcription"] as? [String: Any]
        XCTAssertNil(transcription?["language"])

        var fixed = make()
        fixed.sourceLang = "zh"
        let session2 = fixed.sessionUpdate()["session"] as? [String: Any]
        let t2 = session2?["input_audio_transcription"] as? [String: Any]
        XCTAssertEqual(t2?["language"] as? String, "zh")
    }
}