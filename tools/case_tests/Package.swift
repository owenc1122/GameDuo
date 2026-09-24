// swift-tools-version:5.9
// Runs the platform-independent handheld-case cover logic from DuoDS/App/Cases/Core on macOS.
//   swift test                                  # offline tests
//   HANDHELD_NETWORK_TESTS=1 swift test         # + live GameTDB / libretro lookups and
//                                               #   sample renders in Handheld_Cases/cover_samples/
import PackageDescription

let package = Package(
    name: "CaseTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CaseCore"),  // Sources/CaseCore is a symlink to DuoDS/App/Cases/Core
        .testTarget(name: "CaseCoreTests", dependencies: ["CaseCore"], path: "Tests/CaseCoreTests"),
    ]
)
