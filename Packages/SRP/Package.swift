// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SRP",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SRP", targets: ["SRP"])
    ],
    targets: [
        .target(
            name: "SRP",
            swiftSettings: [
                // The SRP exchange runs a few thousand 2048-bit modular
                // multiplications per sign-in. Unoptimized, that is about two
                // and a half seconds of arithmetic, which every test that
                // signs in pays and which stalls a debug build's sign-in. The
                // module has no debugging value of its own -- it either matches
                // the reference vectors byte for byte or it is broken -- so it
                // is optimized in every configuration.
                .unsafeFlags(["-O"], .when(configuration: .debug))
            ]
        )
    ]
)
