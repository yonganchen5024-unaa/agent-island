// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "IslandReplica", platforms: [.macOS(.v14)], products: [.executable(name: "IslandReplica", targets: ["IslandReplica"])], targets: [.executableTarget(name: "IslandReplica", path: "Sources/IslandReplica")])
