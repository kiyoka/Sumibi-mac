// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SumibiInputPrototype",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SumibiPrototypeCore", targets: ["SumibiPrototypeCore"]),
        .executable(name: "SumibiPrototypeIME", targets: ["SumibiPrototypeIME"])
    ],
    targets: [
        .target(name: "SumibiPrototypeCore"),
        .executableTarget(
            name: "SumibiPrototypeIME",
            dependencies: ["SumibiPrototypeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("InputMethodKit")]
        ),
        .testTarget(name: "SumibiPrototypeCoreTests", dependencies: ["SumibiPrototypeCore"])
    ]
)
