// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PixCapMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PixCapMac",
            targets: ["PixCapMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PixCapMac",
            dependencies: [],
            path: "Sources/PixCapMac",
            cSettings: [
                .headerSearchPath("Bridge")
            ],
            linkerSettings: [
                .unsafeFlags(["-L../../../target/debug", "-lpixcap_ffi"])
            ]
        )
    ]
)
