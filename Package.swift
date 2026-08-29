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
        ),
        // grpc-swift — provides GRPC module (ClientConnection, CallOptions, gRPC exporters)
        .package(
            url: "https://github.com/grpc/grpc-swift.git",
            from: "1.27.0"
        ),
        // swift-nio — provides NIO module (MultiThreadedEventLoopGroup, EventLoopFuture)
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.65.0"
        ),
        // swift-nio-http2 — provides NIOHPACK module (HPACKHeaders for gRPC metadata)
        .package(
            url: "https://github.com/apple/swift-nio-http2.git",
            from: "1.29.0"
        )
    ],
    targets: [
        .target(
            name: "CeburuAnalyticsSDK",
            dependencies: [
                .product(name: "OpenTelemetryApi",              package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk",              package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift"),
                .product(name: "GRPC",                          package: "grpc-swift"),
                .product(name: "NIO",                           package: "swift-nio"),
                .product(name: "NIOHPACK",                      package: "swift-nio-http2")
            ]
        )
    ]
)
