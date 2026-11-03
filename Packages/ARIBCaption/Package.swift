// swift-tools-version: 6.0
import PackageDescription

// libaribcaption's renderer needs CoreText. On Apple platforms the renderer
// sources are compiled into CAribCaptionRenderer. On other platforms the target
// keeps its name but only contains a stub, and the conditional dependency in
// ARIBCaption is never satisfied, so the decoder can still be built and tested
// on Linux.
#if os(macOS)
let rendererTarget = Target.target(
    name: "CAribCaptionRenderer",
    dependencies: [
        .target(name: "CAribCaption"),
    ],
    path: "Sources/CAribCaptionRenderer",
    publicHeadersPath: "include",
    cxxSettings: [
        .headerSearchPath("src"),
        .headerSearchPath("src/include"),
        .headerSearchPath("include"),
        // Internal libaribcaption headers shared with CAribCaption. They are
        // not part of CAribCaption's publicHeadersPath so that importing the C
        // module from Swift never has to parse C++ headers.
        .headerSearchPath("../CAribCaption/src/include"),
        .headerSearchPath("../CAribCaption/src/include/base"),
        .headerSearchPath("../CAribCaption/include/aribcaption"),
    ],
    linkerSettings: [
        .linkedFramework("CoreText", .when(platforms: [.iOS, .macOS])),
        .linkedFramework("CoreGraphics", .when(platforms: [.iOS, .macOS])),
        .linkedFramework("CoreFoundation", .when(platforms: [.iOS, .macOS])),
    ]
)
#else
let rendererTarget = Target.target(
    name: "CAribCaptionRenderer",
    path: "Sources/CAribCaptionRendererStub",
    publicHeadersPath: "include"
)
#endif

let package = Package(
    name: "ARIBCaption",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ARIBCaption", targets: ["ARIBCaption"]),
    ],
    targets: [
        // Decoder, base and C API. Builds everywhere; renderer is disabled by
        // aribcc_config.h outside Apple platforms.
        .target(
            name: "CAribCaption",
            path: "Sources/CAribCaption",
            publicHeadersPath: "include",
            cxxSettings: [
                .define("ARIBCC_IMPLEMENTATION"),
                .headerSearchPath("src"),
                .headerSearchPath("src/include"),
                .headerSearchPath("src/include/base"),
                .headerSearchPath("include"),
                .headerSearchPath("include/aribcaption"),
            ]
        ),
        rendererTarget,
        .target(
            name: "ARIBCaption",
            dependencies: [
                .target(name: "CAribCaption"),
                .target(
                    name: "CAribCaptionRenderer",
                    condition: .when(platforms: [.iOS, .macOS])
                ),
            ]
        ),
        .testTarget(
            name: "ARIBCaptionTests",
            dependencies: ["ARIBCaption"]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
