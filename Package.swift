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
        // The string catalogue (charter §6), embedded in the binary: the same
        // executable is the app and the CLI, and a terminal launch has no
        // bundle to read .lproj tables from. The catalogue stays in Resources/
        // where the charter puts it; this target reaches it through a symlink.
        .target(
            name: "CadastreStrings",
            resources: [.embedInCode("Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "cadastre",
            dependencies: ["CadastreC", "CadastreStrings"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        // The accounting on synthetic trees. outils/verify.sh checks the same
        // rules against real APFS files; these check the corners a real disk
        // rarely produces on demand.
        .testTarget(
            name: "CadastreTests",
            dependencies: ["cadastre", "CadastreStrings"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
