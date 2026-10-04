// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Opt-in only: release/debug configurations alone never enable experimental code.
let developmentFeatures = ProcessInfo.processInfo.environment["SUMIBI_DEVELOPMENT_FEATURES"] == "1"

let package = Package(
    name: "Sumibi",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SumibiCore", targets: ["SumibiCore"]),
        .executable(name: "SumibiIME", targets: ["SumibiIME"])
    ],
    targets: [
        .target(name: "SumibiCore"),
        .executableTarget(
            name: "SumibiIME",
            dependencies: ["SumibiCore"],
            swiftSettings: [.swiftLanguageMode(.v5)] + (developmentFeatures ? [.define("SUMIBI_DEVELOPMENT")] : []),
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("InputMethodKit")]
        ),
        .testTarget(name: "SumibiCoreTests", dependencies: ["SumibiCore"]),
        .testTarget(
            name: "SumibiIMETests",
            dependencies: ["SumibiIME"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
