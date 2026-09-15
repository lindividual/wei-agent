// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Two executables over one library, and the split is the MVP's.
//
// `PiShell` is the app. `pi-shell-cli` is the same client on a terminal: it exists because the
// boundary is the part most likely to be wrong, and finding out that it is — without Xcode, a
// window and a menu in the way — is worth a target. It also means the whole MoonBit half can be
// exercised on a machine that has the archive and nothing else.
//
// The archive is built by `macos/build-moonbit.sh`, not by SwiftPM: it is MoonBit's output, in
// MoonBit's build directory, and pretending otherwise would mean teaching this file the toolchain.
let vendor = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // PiShell/
  .deletingLastPathComponent()  // macos/
  .appendingPathComponent("vendor").path

let linkPiWeb: [LinkerSetting] = [
  .unsafeFlags(
    [
      "-L\(vendor)",
      "-lpiweb",
      // The MoonBit runtime's own dependencies, and the unwind support a panic reports through.
      "-lm",
      "-lc++",
    ],
    .when(platforms: [.macOS])
  )
]

let package = Package(
  name: "PiShell",
  // `.v14` rather than `.v13`: the sidebar is a `NavigationSplitView` with a `List(selection:)` in
  // `sidebar` style, and the toolbar's placement around it is the macOS 14 behaviour — on 13 the same
  // view compiles and puts the button somewhere else. The deployment target is the version the UI is
  // written *for*, not the oldest one it would start on.
  platforms: [.macOS(.v14)],
  targets: [
    // The boundary, in C.
    .target(name: "PiShellC"),

    // The wire and the transcript: what arrives, and what it becomes. No C, no runtime, no
    // window — which is what makes it testable, and what the tests are for.
    .target(name: "PiModel"),

    // The client: a thread, a sink and being the thing SwiftUI watches. The only target that
    // touches the runtime.
    .target(name: "PiKit", dependencies: ["PiModel", "PiShellC"]),

    .executableTarget(
      name: "PiShell",
      dependencies: ["PiKit", "PiShellC"],
      linkerSettings: linkPiWeb
    ),

    .executableTarget(
      name: "pi-shell-cli",
      dependencies: ["PiKit", "PiShellC"],
      linkerSettings: linkPiWeb
    ),

    // The consuming side of the wire, pinned against the same literals the producing side asserts
    // in `macos/appffi/app_wbtest.mbt`. Neither test can see the other, and a rename that only one
    // of them noticed would be two builds that disagree about a field name.
    .testTarget(name: "PiModelTests", dependencies: ["PiModel"]),
  ]
)
