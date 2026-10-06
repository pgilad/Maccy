// swift-tools-version: 6.2
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "Maccy",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Maccy", targets: ["Maccy"])
  ],
  targets: [
    // Storage, analysis, search and retention. No UI, fully unit-tested.
    .target(
      name: "MaccyCore",
      swiftSettings: concurrencySettings,
      // The core uses AppKit only through an Objective-C initializer (RTF), which
      // references no AppKit symbol. Without this setting, the linker drops AppKit
      // from the test bundle and the RTF test crashes. SQLite3 links from its import.
      linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(
      name: "Maccy",
      dependencies: ["MaccyCore"],
      swiftSettings: concurrencySettings + [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(
      name: "MaccyCoreTests",
      dependencies: ["MaccyCore"],
      swiftSettings: concurrencySettings
    ),
  ]
)
