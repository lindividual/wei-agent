// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Two executables over one library, and the split is the MVP's.
//
// `WeiShell` is the app. `wei-cli` is the same client on a terminal: it exists because the
// boundary is the part most likely to be wrong, and finding out that it is — without Xcode, a
// window and a menu in the way — is worth a target. It also means the whole MoonBit half can be
// exercised on a machine that has the archive and nothing else.
//
// The archive is built by `macos/build-moonbit.sh`, not by SwiftPM: it is MoonBit's output, in
// MoonBit's build directory, and pretending otherwise would mean teaching this file the toolchain.
let vendor = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // WeiShell/
  .deletingLastPathComponent()  // macos/
  .appendingPathComponent("vendor").path

let linkWei: [LinkerSetting] = [
  .unsafeFlags(
    [
      "-L\(vendor)",
      "-lwei",
      // The MoonBit runtime's own dependencies, and the unwind support a panic reports through.
      "-lm",
      "-lc++",
    ],
    .when(platforms: [.macOS])
  )
]

let package = Package(
  name: "WeiShell",
  // **The newest macOS, not the oldest one this would start on.** The target is the version the UI is
  // written *for*, and this UI is written for 26: it spends `glassEffect`, it draws the transcript under
  // a toolbar whose background it removes, and it would rather use the API the platform has now than
  // carry an availability branch for one it does not. The cost is stated plainly — the app runs on this
  // macOS and later, and a machine on 15 gets nothing. That is the trade the reader asked for.
  // Written as a string rather than `.v26` because the typed spelling needs
  // `swift-tools-version: 6.2`, and raising that would also switch the package to the Swift 6 language
  // mode — strict concurrency everywhere, which is a much larger change than "target the newest OS".
  // `"26.0"` says the same thing to the build system and changes nothing else.
  platforms: [.macOS("26.0")],
  targets: [
    // The boundary, in C.
    .target(name: "WeiShellC"),

    // The wire and the transcript: what arrives, and what it becomes. No C, no runtime, no
    // window — which is what makes it testable, and what the tests are for.
    .target(name: "WeiModel"),

    // The client: a thread, a sink and being the thing SwiftUI watches. The only target that
    // touches the runtime.
    .target(name: "WeiKit", dependencies: ["WeiModel", "WeiShellC"]),

    .executableTarget(
      name: "WeiShell",
      dependencies: ["WeiKit", "WeiShellC"],
      linkerSettings: linkWei
    ),

    .executableTarget(
      name: "wei-cli",
      dependencies: ["WeiKit", "WeiShellC"],
      linkerSettings: linkWei
    ),

    // The consuming side of the wire, pinned against the same literals the producing side asserts
    // in `macos/appffi/app_wbtest.mbt`. Neither test can see the other, and a rename that only one
    // of them noticed would be two builds that disagree about a field name.
    .testTarget(name: "WeiModelTests", dependencies: ["WeiModel"]),

    // The boundary itself, with the real runtime behind it. It exists for one bug — the app installed
    // a reader but never registered the C callback, so it received nothing and looked like a shell
    // with nothing to say — and it is the only test that can catch that class of failure, because
    // that failure is in the wiring rather than in any decoding. It links the archive, so `swift test`
    // needs `macos/build-moonbit.sh` to have run.
    //
    // It also depends on `WeiShell` itself, which is the one place a test does not follow the split
    // below: the picture a sheet exports (`PictureExport`) is a view rendered into a bitmap, and a view
    // rendered into a bitmap is not a fact about the wire. Everything about it that *is* arithmetic is
    // in `WeiModel` where this cannot reach it; what is left — which pixels the file has, and whether
    // the picture under the ink is right way up — can only be checked against a real `ImageRenderer`.
    .testTarget(
      name: "WeiShellTests",
      dependencies: ["WeiKit", "WeiShellC", "WeiShell"],
      linkerSettings: linkWei
    ),
  ]
)
