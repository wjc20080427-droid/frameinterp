// swift-tools-version:6.0
import Foundation
import PackageDescription

// FI_XNATIVE=1：链接 WebRTC，带原生 Xbox 串流（2.6 起发布版默认带；make-app.sh 在 Vendor/WebRTC.xcframework 存在时自动打开）。
// FI_KEYPAD=1：测试版的键盘当手柄（./make-app.sh keypad）。
// WebRTC.xcframework 是 stasel/WebRTC 社区编译的 Google WebRTC（M158，BSD），放在 Vendor/（不进 git，tools/fetch-webrtc.sh 下载并核对校验和）。
let xnative = ProcessInfo.processInfo.environment["FI_XNATIVE"] == "1"
let keypad = ProcessInfo.processInfo.environment["FI_KEYPAD"] == "1"

let package = Package(
    name: "mac-frame-interp",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "FrameInterp",
            dependencies: xnative ? ["WebRTC"] : [],
            path: "Sources/FrameInterp",
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
                + (xnative ? [.define("FI_XNATIVE")] : []) + (keypad ? [.define("FI_KEYPAD")] : []),
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"), .linkedFramework("QuartzCore"), .linkedFramework("CoreAudio"),
                // 嵌入 Info.plist，摄像头/麦克风权限弹窗需要用途说明
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/FrameInterp/Info.plist"]),
            ] + (xnative ? [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])] : [])
        )
    ] + (xnative ? [.binaryTarget(name: "WebRTC", path: "Vendor/WebRTC.xcframework")] : []),
    swiftLanguageModes: [.v5]
)
