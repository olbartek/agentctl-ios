// swift-tools-version: 6.1
import PackageDescription

// AgentShop: the showcase app. One package holds every module of the app — models, design system, mocked clients,
// features and the host's CLI — so `swift test` and `./appctl` need no workspace. The Xcode project in `App/`
// is only the app shell and its UI tests.
//
// AgentCtl comes from this repository itself, by path. A path dependency's identity is its directory's name,
// which is why the products below name the package `agentctl-ios`: clone the repository under that name (the
// `git clone` default). A host app depends on the published package instead:
// `.package(url: "https://github.com/olbartek/agentctl-ios", from: "0.3.0")`.

let tca: Target.Dependency = .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
let agentCore: Target.Dependency = .product(name: "AgentCtlCore", package: "agentctl-ios")
let agentTCA: Target.Dependency = .product(name: "AgentCtlTCA", package: "agentctl-ios")
/// What every client and feature builds on.
let base: [Target.Dependency] = ["Models", agentCore, tca]
/// What every feature builds on.
let feature: [Target.Dependency] = base + ["DesignSystem"]

let package = Package(
  name: "AgentShop",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    // The two libraries the app target links.
    .library(name: "AppFeature", targets: ["AppFeature"]),
    .library(name: "AgentShopCtl", targets: ["AgentShopCtl"]),
    .executable(name: "shopctl", targets: ["shopctl"]),
  ],
  dependencies: [
    .package(path: "../.."),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
  ],
  targets: [
    // Core
    .target(name: "Models", dependencies: [agentCore, .product(name: "Dependencies", package: "swift-dependencies")]),
    .target(name: "DesignSystem", dependencies: ["Models"], resources: [.process("Resources")]),

    // Mocked clients: every method goes through `shopCall`, so `mock <client.method> <error>` can fail it.
    .target(name: "AuthClient", dependencies: base),
    .target(name: "SessionClient", dependencies: base),
    .target(name: "OrdersClient", dependencies: base + ["SessionClient"]),

    // Features
    .target(name: "AuthFeature", dependencies: feature + ["AuthClient"]),
    .target(name: "HomeFeature", dependencies: feature + ["OrdersClient"]),
    .target(name: "AppFeature", dependencies: feature + ["AuthFeature", "HomeFeature", "AuthClient", "SessionClient"]),

    // The host's AgentCtl integration and its CLI.
    .target(
      name: "AgentShopCtl",
      dependencies: base + [agentTCA, "AppFeature", "AuthClient", "SessionClient", "OrdersClient"]
    ),
    .executableTarget(
      name: "shopctl",
      dependencies: ["AgentShopCtl", .product(name: "AgentCtlCLI", package: "agentctl-ios")]
    ),

    // Tests
    .testTarget(name: "ModelsTests", dependencies: ["Models"]),
    .testTarget(name: "AuthClientTests", dependencies: base + ["AuthClient"]),
    .testTarget(name: "SessionClientTests", dependencies: base + ["SessionClient"]),
    .testTarget(name: "OrdersClientTests", dependencies: base + ["OrdersClient", "SessionClient"]),
    .testTarget(name: "AuthFeatureTests", dependencies: feature + ["AuthFeature", "AuthClient"]),
    .testTarget(name: "HomeFeatureTests", dependencies: feature + ["HomeFeature", "OrdersClient"]),
    .testTarget(
      name: "AppFeatureTests",
      dependencies: feature + ["AppFeature", "AuthFeature", "HomeFeature", "AuthClient", "SessionClient"]
    ),
    .testTarget(
      name: "AgentShopCtlTests",
      dependencies: base + [
        "AgentShopCtl", "AppFeature", "AuthClient", "SessionClient", "OrdersClient", agentTCA,
        .product(name: "AgentCtlTestSupport", package: "agentctl-ios"),
      ]
    ),
  ]
)
