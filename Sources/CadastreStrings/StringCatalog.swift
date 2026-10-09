import Foundation

/// `Resources/Localizable.xcstrings`, embedded in the binary at build time.
///
/// A target of its own because SwiftPM only embeds files that sit under the
/// target's path, and the charter keeps the catalogue in `Resources/` at the
/// root (§3). This target's path is the package root; its only source is this
/// file, its only resource the catalogue.
public enum StringCatalog {
    public static var data: Data { Data(PackageResources.Localizable_xcstrings) }
}
