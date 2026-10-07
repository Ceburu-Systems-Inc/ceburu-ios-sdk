// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CeburuAnalyticsSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)   // required for swift build on macOS (CLI / CI); iOS is the primary target
    ],
    products: [
        .library(name: "CeburuAnalyticsSDK", targets: ["CeburuAnalyticsSDK"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            from: "2.4.1"
        ),
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift.git",
            from: "2.3.0"
        )
        // grpc-swift, swift-nio, swift-nio-http2 removed — transport switched to OTLP/HTTP
    ],
    targets: [
        .target(
            name: "CeburuAnalyticsSDK",
            dependencies: [
                .product(name: "OpenTelemetryApi",                   package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk",                   package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporterHTTP",   package: "opentelemetry-swift")
            ]
        ),
        .testTarget(
            name: "CeburuAnalyticsSDKTests",
            dependencies: ["CeburuAnalyticsSDK"]
        )
    ]
)