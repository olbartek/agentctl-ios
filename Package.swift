// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "AgentCtl",
  platforms: [.iOS(.v18), .macOS(.v15)],
  // Declare only the products whose targets exist: Task 13 adds the rest as it lands.
  products: [
    .library(name: "AgentCtlCore", targets: ["AgentCtlCore"]),
    .library(name: "AgentCtlTCA", targets: ["AgentCtlTCA"]),
    .library(name: "AgentCtlBridge", targets: ["AgentCtlBridge"]),
    .library(name: "AgentCtlCLI", targets: ["AgentCtlCLI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.6"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
  ],
  targets: [
    .target(
      name: "AgentCtlCore",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Clocks", package: "swift-clocks"),
      ]
    ),
    .target(
      name: "AgentCtlTCA",
      dependencies: [
        "AgentCtlCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // The in-app HTTP bridge: `#if DEBUG` from end to end, so a Release build of a host app compiles it away.
    .target(
      name: "AgentCtlBridge",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlTCA",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // The CLI as a library: a host's own executable is 4 lines that hand it an `AppCtlConfig`. It drives
    // `xcodebuild`, `simctl` and SwiftPM through `Process`, none of which exists on iOS, so every file is
    // wrapped in `#if os(macOS)`: building this package for an iOS destination compiles the target to nothing
    // instead of failing. SwiftPM has no per-target platform setting, which is why the guard lives in the
    // sources.
    .target(
      name: "AgentCtlCLI",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlTCA",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "AgentCtlTests",
      // AgentCtlCLI so the help pages and the messages that name the CLI can be rendered and asserted on;
      // its files are `#if os(macOS)`, and so is the test that reads them.
      dependencies: ["AgentCtlTCA", "AgentCtlCLI"]
    ),
  ]
)
