// swift-tools-version: 6.1
import PackageDescription

// TinyMVVM: TinyApp rebuilt as MVVM-C, with `@Observable` view models under a coordinator and no TCA. It is its own
// package, like AgentShop, because Swift's Observation needs iOS 17, while AgentCtl itself supports iOS 16.
//
// AgentCtl comes from this repository itself, by path. A path dependency's identity is its directory's name, which
// is why the products below name the package `agentctl-ios`: clone the repository under that name (the `git clone`
// default). A host app depends on the published package instead:
// `.package(url: "https://github.com/olbartek/agentctl-ios", from: "0.10.0")`.

let package = Package(
  name: "TinyMVVM",
  platforms: [.iOS(.v17), .macOS(.v15)],
  products: [
    .library(name: "TinyMVVM", targets: ["TinyMVVM"]),
    .executable(name: "tinymvvmctl", targets: ["tinymvvmctl"]),
  ],
  dependencies: [
    .package(path: "../.."),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
  ],
  targets: [
    // The app: view models, the coordinator and the mocked client, driven through AgentCtlObservation.
    .target(
      name: "TinyMVVM",
      dependencies: [
        .product(name: "AgentCtlCore", package: "agentctl-ios"),
        .product(name: "AgentCtlObservation", package: "agentctl-ios"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .executableTarget(
      name: "tinymvvmctl",
      dependencies: ["TinyMVVM", .product(name: "AgentCtlCLI", package: "agentctl-ios")]
    ),
    // TinyApp's scenarios and transcripts, run on TinyMVVM: the same bytes, the same exits.
    .testTarget(
      name: "TinyMVVMTests",
      dependencies: [
        "TinyMVVM",
        .product(name: "AgentCtlCore", package: "agentctl-ios"),
        .product(name: "AgentCtlRuntime", package: "agentctl-ios"),
        .product(name: "AgentCtlObservation", package: "agentctl-ios"),
        .product(name: "AgentCtlTestSupport", package: "agentctl-ios"),
      ],
      // Read by path, not bundled.
      exclude: ["Fixtures"]
    ),
  ]
)
