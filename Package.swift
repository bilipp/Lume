// swift-tools-version: 5.9
import PackageDescription

/// This manifest exists only to vendor developer tooling — it does NOT build the
/// Lume app (that's Lume.xcodeproj). It pins the git-hook + lint/format tools as
/// SPM plugins so contributors don't need separate Homebrew/Mint installs.
/// Hook definitions live in lefthook.yml; set up via Scripts/setup.sh.
let package = Package(
    name: "LumeTooling",
    dependencies: [
        .package(url: "https://github.com/csjones/lefthook-plugin.git", exact: "2.1.9"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins.git", exact: "0.63.2"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", exact: "0.61.1")
    ]
)
