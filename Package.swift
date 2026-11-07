// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheICalMCP",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.0")),
        .package(url: "https://github.com/PsychQuant/che-mcp-kit-swift.git", .upToNextMinor(from: "0.2.0"))
    ],
    targets: [
        .target(
            name: "CheICalMCPObjC",
            path: "Sources/CheICalMCPObjC"
        ),
        .executableTarget(
            name: "CheICalMCP",
            dependencies: [
                "CheICalMCPObjC",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "CheMCPKit", package: "che-mcp-kit-swift")
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
        .target(
            name: "CheICalMCPObjCTestSupport",
            path: "Tests/CheICalMCPObjCTestSupport"
        ),
        .testTarget(
            name: "CheICalMCPTests",
            dependencies: ["CheICalMCP", "CheICalMCPObjC", "CheICalMCPObjCTestSupport"],
            path: "Tests/CheICalMCPTests"
        )
    ]
)
