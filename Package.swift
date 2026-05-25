// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheICalMCP",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0"))
    ],
    targets: [
        .executableTarget(
            name: "CheICalMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/CheICalMCP",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CheICalMCP/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "CheICalMCPTests",
            dependencies: ["CheICalMCP"],
            path: "Tests/CheICalMCPTests"
        )
    ]
)
