// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "agent-ctl",
  platforms: [.iOS(.v16), .macOS(.v15)],
  products: [
    .library(name: "AgentCtlCore", targets: ["AgentCtlCore"]),
    .library(name: "AgentCtlRuntime", targets: ["AgentCtlRuntime"]),
    .library(name: "AgentCtlTCA", targets: ["AgentCtlTCA"]),
    .library(name: "AgentCtlObservation", targets: ["AgentCtlObservation"]),
    .library(name: "AgentCtlBridge", targets: ["AgentCtlBridge"]),
    .library(name: "AgentCtlCLI", targets: ["AgentCtlCLI"]),
    .library(name: "AgentCtlTestSupport", targets: ["AgentCtlTestSupport"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.4.1"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.7.3"),
  ],
  targets: [
    .target(
      name: "AgentCtlCore",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    // AgentCtlRuntime, the two adapters, AgentCtlCLI and AgentCtlTestSupport compile to nothing in a release build:
    // every file is `#if DEBUG || AGENTCTL_RELEASE`. A host's app links a config module that depends on them, and
    // SwiftPM cannot drop a dependency per build configuration, so without this the runtime would ship, unreachable,
    // in the app. A CLI that is itself built in release passes `-Xswiftc -DAGENTCTL_RELEASE` (Templates/appctl
    // does), which reaches every target. AgentCtlCore stays: features' `+Agent.swift` files use it and ship.
    //
    // The engine, whatever the app's architecture: the runner, the hosts, settling, the config. It drives an app
    // through an `AgentDriver`; the two adapters below are the drivers.
    .target(
      name: "AgentCtlRuntime",
      dependencies: [
        "AgentCtlCore",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
      ]
    ),
    // The Composable Architecture's driver: a `Store` and its root reducer.
    .target(
      name: "AgentCtlTCA",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlRuntime",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // MVVM-C's driver: `@Observable` view models and a coordinator that owns navigation. No TCA.
    .target(
      name: "AgentCtlObservation",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlRuntime",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),
    // The in-app HTTP bridge: `#if DEBUG` from end to end, so a Release build of a host app compiles it away.
    .target(
      name: "AgentCtlBridge",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlRuntime",
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
        "AgentCtlRuntime",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    // The coverage guards and scenario checks a host's test target depends on. A plain `.target`, not a
    // `.testTarget`: it has no dependency on a testing framework, so a host writes its own `@Test`/`XCTestCase`
    // around it.
    .target(
      name: "AgentCtlTestSupport",
      dependencies: [
        "AgentCtlCore",
        // `AgentCoverage` is generic over the app's driver, like the runner it drives.
        "AgentCtlRuntime",
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
    // TinyApp as MVVM-C: `@Observable` view models under a coordinator, driven through AgentCtlObservation. No TCA.
    // It runs TinyApp's scenario files, and the tests compare its output with TinyApp's byte for byte.
    .target(
      name: "TinyMVVM",
      dependencies: [
        "AgentCtlCore",
        "AgentCtlObservation",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ],
      path: "Examples/TinyMVVM/Sources/TinyMVVM"
    ),
    .executableTarget(
      name: "tinymvvmctl",
      dependencies: ["TinyMVVM", "AgentCtlCLI"],
      path: "Examples/TinyMVVM/Sources/tinymvvmctl"
    ),
    .testTarget(
      name: "AgentCtlTests",
      // AgentCtlCLI so the help pages and the messages that name the CLI can be rendered and asserted on;
      // its files are `#if os(macOS)`, and so is the test that reads them. TinyApp is the fixture for every
      // test that needs a real app to drive. AgentCtlTestSupport is proved against that same fixture below.
      dependencies: [
        "AgentCtlCore", "AgentCtlTCA", "AgentCtlObservation", "AgentCtlBridge", "AgentCtlCLI", "AgentCtlTestSupport",
        "TinyApp", "TinyMVVM",
      ],
      // Read by path (`PackageRoot`), not bundled.
      exclude: ["Fixtures"]
    ),
    // A host's own public types named with common words (`PermissionStatus`, `Location`, …), and a test that
    // names each unqualified beside every AgentCtl module: a library type of the same name fails the build.
    .target(name: "HostNames", path: "Tests/HostNames"),
    .testTarget(
      name: "HostNamesTests",
      dependencies: [
        "HostNames", "AgentCtlCore", "AgentCtlRuntime", "AgentCtlTCA", "AgentCtlObservation", "AgentCtlBridge",
        "AgentCtlCLI", "AgentCtlTestSupport",
      ]
    ),
  ]
)
