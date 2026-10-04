// swift-tools-version:5.10
import PackageDescription

// LiveSub —— iOS 实时翻译字幕插件（协议层）。
//
// 协议层/重采样/事件语义移植自 ReaLingo（github.com/noSugarK/ReaLingo，MIT）：
//   src-tauri/src/realtime.rs  → Sources/LiveSubCore/RealtimeClient.swift + TranslateEvent.swift
//   src-tauri/src/resample.rs  → Sources/LiveSubCore/Resampler.swift
//   src-tauri/src/config.rs    → Sources/LiveSubCore/Settings.swift
//   src-tauri/src/audio.rs     → ChunkQueue 的 64 块/100ms 语义（采集后端 iOS 侧另写）
//
// 本包零外部依赖：单测可在 macOS runner 上直接 swift test。

let package = Package(
    name: "LiveSub",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "LiveSubCore", targets: ["LiveSubCore"]),
        .executable(name: "livesub-probe", targets: ["livesub_probe"]),
    ],
    targets: [
        .target(name: "LiveSubCore"),
        .executableTarget(name: "livesub_probe", dependencies: ["LiveSubCore"]),
        .testTarget(name: "LiveSubCoreTests", dependencies: ["LiveSubCore"]),
    ]
)