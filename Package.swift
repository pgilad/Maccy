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
      linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("AppKit")]
    ),
    .executableTarget(
      name: "Maccy",
      dependencies: ["MaccyCore"],
      swiftSettings: concurrencySettings + [.defaultIsolation(MainActor.self)],
      linkerSettings: [.linkedFramework("Carbon")]
    ),
    .testTarget(
      name: "MaccyCoreTests",
      dependencies: ["MaccyCore"],
      swiftSettings: concurrencySettings
    ),
  ]
)
