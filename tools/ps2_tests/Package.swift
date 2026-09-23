// swift-tools-version:5.9
// Runs the platform-independent PS2 logic from DuoDS/App/PS2/Core on macOS.
import PackageDescription

let package = Package(
    name: "PS2Tests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PS2Core"),  // Sources/PS2Core is a symlink to DuoDS/App/PS2/Core
        .testTarget(name: "PS2CoreTests", dependencies: ["PS2Core"],
                    path: "Tests/PS2CoreTests", resources: [.copy("Fixtures")]),
    ]
)
