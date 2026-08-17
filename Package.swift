// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TailnetKit",
    // String form rather than .v15/.v17: those enum cases need tools 6.0, and
    // staying on 5.9 keeps the package in Swift 5 language mode, matching the
    // apps that consume it.
    platforms: [.macOS("15.0"), .iOS("17.0")],
    products: [
        .library(name: "TailnetKit", targets: ["TailnetKit"]),
        .library(name: "TailnetKitUI", targets: ["TailnetKitUI"]),
    ],
    targets: [
        // Built by `make bootstrap` from Vendor/libtailscale — not checked in
        // (the three slices total ~100MB). A missing artifact fails package
        // resolution with a path error; run `make bootstrap` to produce it.
        .binaryTarget(
            name: "TailscaleKit",
            path: "binary/TailscaleKit.xcframework"),
        .target(name: "TailnetKit", dependencies: ["TailscaleKit"]),
        .target(name: "TailnetKitUI", dependencies: ["TailnetKit"]),
        .testTarget(name: "TailnetKitTests", dependencies: ["TailnetKit"]),
    ]
)
