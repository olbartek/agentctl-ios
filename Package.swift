// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "agent-ctl",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "AgentCtlCore", targets: ["AgentCtlCore"]),
    .library(name: "AgentCtlTCA", targets: ["AgentCtlTCA"]),
    .library(name: "AgentCtlBridge", targets: ["AgentCtlBridge"]),
    .library(name: "AgentCtlCLI", targets: ["AgentCtlCLI"]),
    .library(name: "AgentCtlTestSupport", targets: ["AgentCtlTestSupport"]),
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
    // The coverage guards a host's test target depends on. A plain `.target`, not a `.testTarget`: it has no
    // dependency on a testing framework, so a host writes its own `@Test`/`XCTestCase` around it.
    .target(
      name: "AgentCtlTestSupport",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlTCA",
      ]
    ),
    // The example app, and its CLI. Targets of this package rather than a nested package: the tests below use
    // TinyApp as their fixture, and a nested package depending on this one would be a dependency cycle.
    // Neither target is a product, so a consumer of the libraries never builds them.
    .target(
      name: "TinyApp",
      dependencies: [
        "AgentCtlCore",
        // AgentCtlTCA as well, because `TinyAppConfig` is an `AppCtlConfig` and builds the two hosts.
        "AgentCtlTCA",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ],
      path: "Examples/TinyApp/Sources/TinyApp"
    ),
    .executableTarget(
      name: "tinyctl",
      // AgentCtlTCA comes through TinyApp, which is what `main.swift` imports alongside the CLI.
      dependencies: ["TinyApp", "AgentCtlCLI"],
      path: "Examples/TinyApp/Sources/tinyctl"
    ),
    .testTarget(
      name: "AgentCtlTests",
      // AgentCtlCLI so the help pages and the messages that name the CLI can be rendered and asserted on;
      // its files are `#if os(macOS)`, and so is the test that reads them. TinyApp is the fixture for every
      // test that needs a real app to drive. AgentCtlTestSupport is proved against that same fixture below.
      dependencies: ["AgentCtlCore", "AgentCtlTCA", "AgentCtlBridge", "AgentCtlCLI", "AgentCtlTestSupport", "TinyApp"]
    ),
  ]
)
