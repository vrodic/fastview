// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FastView",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "FastView", targets: ["FastView"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
        .package(url: "https://github.com/mtgto/Unrar.swift", .upToNextMajor(from: "0.2.0"))
    ],
    targets: [
        .target(
            name: "FastView",
            dependencies: [
                "ZIPFoundation",
                "CFastViewShm",
                "FastViewArchiveCore",
                .product(name: "Unrar", package: "Unrar.swift")
            ],
            path: "Sources/FastView",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        // Shared-memory helpers for FastView and FastViewReader.
        .target(name: "CFastViewShm"),
        // Archive listing/extraction and shared-memory regions, used by both
        // FastView and FastViewReader.
        .target(
            name: "FastViewArchiveCore",
            dependencies: [
                "CFastViewShm",
                .product(name: "Unrar", package: "Unrar.swift")
            ]
        ),
        // Killable helper process that does all archive I/O and exchanges
        // data through shared memory; built next to the FastView executable.
        .executableTarget(
            name: "FastViewReader",
            dependencies: ["CFastViewShm", "FastViewArchiveCore"]
        ),
        .testTarget(
            name: "FastViewTests",
            dependencies: ["FastView", "FastViewReader", "FastViewArchiveCore", "ZIPFoundation"],
            path: "Tests/FastViewTests"
        )
    ]
)
