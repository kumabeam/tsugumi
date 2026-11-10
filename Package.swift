// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tsugumi",
    platforms: [.macOS(.v15)],
    dependencies: [
        // アプリ内アップデート
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tsugumi",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tsugumi",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework は Tsugumi.app/Contents/Frameworks に入れるので、そこを探しに行かせる
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
