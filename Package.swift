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
        .testTarget(
            name: "FastViewTests",
            // ZIPFoundation is the reference the ZIP directory parser is checked against.
            dependencies: ["FastView", "ZIPFoundation"],
            path: "Tests/FastViewTests"
        )
    ]
)
