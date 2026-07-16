// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hidpi",
    targets: [
        .target(
            name: "CDisplayPrivate",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "hidpi",
            dependencies: ["CDisplayPrivate"]
        ),
    ]
)
