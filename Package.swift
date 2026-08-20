// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobileOTelSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MobileOTelSDK", targets: ["MobileOTelSDK"])
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
    ],
    targets: [
        .target(
            name: "MobileOTelSDK",
            dependencies: [
                .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
                .product(name: "OpenTelemetryProtocolExporter", package: "opentelemetry-swift")
            ]
        )
    ]
)
