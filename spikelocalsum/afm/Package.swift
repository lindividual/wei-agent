// swift-tools-version: 6.2
import PackageDescription

// A spike, deliberately outside the app's build: it is a measurement harness, not
// a feature, and it should be possible to delete it by deleting the directory.
//
// It links FoundationModels directly rather than through `WeiShell`, because the
// question it answers — should the app ever call a local model — should be settled
// before anything is wired through the FFI boundary.
let package = Package(
    name: "afmdigest",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "afmdigest",
            path: "Sources/afmdigest"
        )
    ]
)
