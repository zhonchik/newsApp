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
                exclude: ["Assets.xcassets", "Resources/Readability-LICENSE.md", "ArticlePreparation.swift", "ArticleWebView.swift", "HybridArticleReader.swift", "CurrentApp.swift", "ReaderAppDelegate.swift", "ReaderState.swift", "ReaderView.swift", "SettingsView.swift", "SubscriptionsView.swift", "ThemeSettings.swift"],
                sources: ["FeedService.swift", "NativeArticleView.swift", "NativeArticleBody.swift", "ReaderPage.swift", "ReaderAppearance.swift", "ReaderPresentation.swift", "ReaderHistory.swift", "ReaderScrollView.swift", "Models.swift", "LibraryWorker.swift", "MediaCache.swift"],
                resources: [.copy("Resources/Readability.js")]),
        .testTarget(name: "ReaderContentTests", dependencies: ["ReaderContent"]),
        .testTarget(name: "ReaderRuntimeTests", dependencies: ["ReaderRuntime", "ReaderContent"])
    ]
)
