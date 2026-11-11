// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReaderContent", platforms: [.macOS(.v14)], products: [.library(name: "ReaderContent", targets: ["ReaderContent"])], dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")], targets: [.target(name: "ReaderContent", dependencies: ["SwiftSoup"], path: "ReaderContent"), .testTarget(name: "ReaderContentTests", dependencies: ["ReaderContent"])])
