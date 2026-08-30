// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DJI4GConnect",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DJI4GConnect", targets: ["DJI4GConnect"])
    ],
    targets: [
        .executableTarget(name: "DJI4GConnect", dependencies: ["LibUSBBridge"]),
        .target(
            name: "LibUSBBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        )
    ]
)
