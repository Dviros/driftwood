// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "driftwood-app",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "Driftwood", path: "Sources/Driftwood")
  ]
)
