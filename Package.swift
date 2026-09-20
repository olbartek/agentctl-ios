// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "AgentCtl",
  platforms: [.iOS(.v18), .macOS(.v15)],
  // Declare only the products whose targets exist: Tasks 11 and 13 add the rest as they land.
  products: [
    .library(name: "AgentCtlCore", targets: ["AgentCtlCore"]),
    .library(name: "AgentCtlTCA", targets: ["AgentCtlTCA"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.2"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.6"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
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
    .testTarget(
      name: "AgentCtlTests",
      dependencies: ["AgentCtlTCA"]
    ),
  ]
)
