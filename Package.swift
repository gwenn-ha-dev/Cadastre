// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadastre",
    // v14 for NSSplitViewItem's inspector behaviour, which is what gives the
    // trailing panel its proper material and divider instead of a hand-rolled
    // subview pretending to be one.
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CadastreC"),
        .executableTarget(
            name: "cadastre",
            dependencies: ["CadastreC"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // The accounting on synthetic trees. outils/verify.sh checks the same
        // rules against real APFS files; these check the corners a real disk
        // rarely produces on demand.
        .testTarget(
            name: "CadastreTests",
            dependencies: ["cadastre"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
