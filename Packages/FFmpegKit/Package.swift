// swift-tools-version: 6.0
import PackageDescription

// FFmpeg n9 (demuxing and the mp4 muxer for the MKV support, phase 2) and libmpv 0.41 (the compatibility engine,
// phase 3), both from the MPVKit project's release 1.1.0-n9.0.2: prebuilt static xcframeworks, the LGPL variant
// (the plain `MPVKit` product, not `MPVKit-GPL`). One package supplies both so the app links FFmpeg only once; before
// phase 3 this package pinned the same four FFmpeg binaries (identical checksums) by itself.
// MPVKit also brings libass, libplacebo, MoltenVK (Vulkan on Metal), shaderc, gnutls/openssl and friends.
// Static LGPL linking: see PLAN.md section 9 (the app must stay relinkable).
let package = Package(
    name: "FFmpegKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
    ],
    dependencies: [
        // The commit tagged 1.1.0-n9.0.2, by hash: a tag can be moved, and these libraries parse every file the app opens.
        .package(url: "https://github.com/mpvkit/MPVKit.git", revision: "98c3453e252922e3136422da3fbb2e341ed9edc8"),
    ],
    targets: [
        .target(
            name: "FFmpegKit",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            linkerSettings: [
                // Xcode links only what a target names, not what MPVKit's own targets depend on, so the static libraries
                // libmpv and FFmpeg were built against are named here (the list is MPVKit's `_FFmpeg` and `_MPVKit` targets).
                .linkedFramework("Libmpv"), .linkedFramework("Libavfilter"), .linkedFramework("Libavdevice"), .linkedFramework("Libswscale"),
                .linkedFramework("Libass"), .linkedFramework("Libfreetype"), .linkedFramework("Libfribidi"), .linkedFramework("Libharfbuzz"),
                .linkedFramework("Libunibreak"), .linkedFramework("Libplacebo"), .linkedFramework("Libdovi"),
                .linkedFramework("Libshaderc_combined"), .linkedFramework("lcms2"),
                .linkedFramework("Libuchardet"), .linkedFramework("Libbluray"), .linkedFramework("Libluajit"),
                .linkedFramework("Libssl"), .linkedFramework("Libcrypto"), .linkedFramework("gnutls"), .linkedFramework("nettle"),
                .linkedFramework("hogweed"), .linkedFramework("gmp"), .linkedFramework("Libdav1d"), .linkedFramework("Libuavs3d"),
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("IOSurface"), .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"), .linkedFramework("AppKit"),
                .linkedLibrary("MoltenVK"), .linkedFramework("IOKit"), .linkedFramework("CoreGraphics"), .linkedLibrary("expat"), .linkedLibrary("c++"),
            ]
        ),
    ]
)
