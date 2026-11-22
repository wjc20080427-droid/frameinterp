// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mac-frame-interp",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "FrameInterp",
            path: "Sources/FrameInterp",
            exclude: ["Info.plist"],
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AVFoundation"), .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"), .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"), .linkedFramework("QuartzCore"), .linkedFramework("CoreAudio"),
                // 嵌入 Info.plist，摄像头/麦克风权限弹窗需要用途说明
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "Sources/FrameInterp/Info.plist"]),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
