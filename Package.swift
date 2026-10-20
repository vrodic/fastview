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
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0"))
    ],
    targets: [
        .target(
            name: "UnrarC",
            path: "Sources/UnrarC",
            publicHeadersPath: "include",
            cSettings: [
                .define("SILENT"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP")
            ]
        ),
        .target(
            name: "FastView",
            dependencies: [
                "ZIPFoundation",
                "UnrarC"
            ],
            path: "Sources/FastView",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
