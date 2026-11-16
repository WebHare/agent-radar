// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "agent-radar",
  platforms: [.macOS(.v14)],
  targets: [
    .target(
      name: "RadarKit",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "AgentRadar",
      dependencies: ["RadarKit"]
    ),
    .testTarget(
      name: "RadarKitTests",
      dependencies: ["RadarKit"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
