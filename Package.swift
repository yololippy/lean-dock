// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LeanDock",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LeanDock", targets: ["LeanDock"]),
               .executable(name: "LeanDockChecks", targets: ["LeanDockChecks"])],
    targets: [
        .systemLibrary(name: "CPlatform", path: "Sources/CPlatform"),
        .target(name: "LeanDockCore", dependencies: ["CPlatform"],
                resources: [.copy("Resources/Icons")],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOKit"), .linkedLibrary("sqlite3")]),
        .executableTarget(name: "LeanDock", dependencies: ["LeanDockCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]),
        .executableTarget(name: "LeanDockChecks", dependencies: ["LeanDockCore", "CPlatform"]),
    ],
    swiftLanguageModes: [.v5]
)
