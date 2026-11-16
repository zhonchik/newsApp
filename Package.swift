// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReaderContent",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ReaderContent", targets: ["ReaderContent"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")],
    targets: [
        .target(name: "ReaderContent", dependencies: ["SwiftSoup"], path: "ReaderContent"),
        .target(name: "ReaderRuntime", dependencies: ["ReaderContent", "SwiftSoup"], path: "App",
                exclude: ["Assets.xcassets", "Resources", "ArticlePreparation.swift", "ArticleWebView.swift", "CurrentApp.swift", "FeedService.swift", "FirstFrameGate.swift", "ReaderState.swift", "ReaderView.swift", "SettingsView.swift", "SubscriptionsView.swift", "ThemeSettings.swift"],
                sources: ["Models.swift", "LibraryWorker.swift", "MediaCache.swift"]),
        .testTarget(name: "ReaderContentTests", dependencies: ["ReaderContent"]),
        .testTarget(name: "ReaderRuntimeTests", dependencies: ["ReaderRuntime", "ReaderContent"])
    ]
)
