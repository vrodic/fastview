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
            exclude: [
                "arccmt.cpp",
                "blake2s_sse.cpp",
                "blake2sp.cpp",
                "cmdfilter.cpp",
                "cmdmix.cpp",
                "coder.cpp",
                "crypt1.cpp",
                "crypt2.cpp",
                "crypt3.cpp",
                "crypt5.cpp",
                "hardlinks.cpp",
                "log.cpp",
                "model.cpp",
                "recvol3.cpp",
                "recvol5.cpp",
                "suballoc.cpp",
                "threadmisc.cpp",
                "uicommon.cpp",
                "uiconsole.cpp",
                "uisilent.cpp",
                "ulinks.cpp",
                "unpack15.cpp",
                "unpack20.cpp",
                "unpack30.cpp",
                "unpack50.cpp",
                "unpack50frag.cpp",
                "unpack50mt.cpp",
                "unpackinline.cpp",
                "uowners.cpp",
                "win32acl.cpp",
                "win32lnk.cpp",
                "win32stm.cpp"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("SILENT"),
                .define("RARDLL"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("RAR_SMP")
            ],
            cxxSettings: [
                .define("SILENT"),
                .define("RARDLL"),
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
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "FastViewTests",
            dependencies: ["FastView"],
            path: "Tests/FastViewTests"
        )
    ]
)
