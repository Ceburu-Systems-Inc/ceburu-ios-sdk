// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileLoggingSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MobileLoggingSDK", targets: ["MobileLoggingSDK"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            from: "2.4.1"
        )
    ],
    targets: [
        .target(
            name: "MobileLoggingSDK",
            dependencies: [
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core")
            ]
        )
    ]
)
