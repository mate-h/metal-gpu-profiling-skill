// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "metal-debug-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "metal-debug-mcp", targets: ["metal-debug-mcp"]),
        .executable(name: "metal-debug-sample", targets: ["metal-debug-sample"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "metal-debug-mcp",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        .executableTarget(name: "metal-debug-sample"),
    ]
)
