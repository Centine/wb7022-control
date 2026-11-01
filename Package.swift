// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WB7022Control",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CUVC",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "WB7022Control",
            dependencies: ["CUVC"],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreImage")]
        ),
    ]
)
