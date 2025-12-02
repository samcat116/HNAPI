// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HNAPI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "HNAPI", targets: ["HNAPI"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.11.2")],
    targets: [
        .target(
            name: "HNAPI",
            dependencies: ["SwiftSoup"],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
