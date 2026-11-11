// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "MacVM",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "macvm", targets: ["MacVMCLI"]),
        .executable(name: "MacVMApp", targets: ["MacVMApp"]),
        .executable(name: "macvm-netd", targets: ["MacVMNetHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "MacVMModel", swiftSettings: strict),
        .target(name: "MacVMPrivate", swiftSettings: strict),
        .target(
            name: "MacVMEngine",
            dependencies: ["MacVMModel", "MacVMPrivate"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MacVMCLI",
            dependencies: [
                "MacVMModel", "MacVMEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MacVMApp",
            dependencies: ["MacVMModel", "MacVMEngine", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: strict,
            // App 包里 Sparkle.framework 放在 Contents/Frameworks。
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "MacVMNetHelper", dependencies: ["MacVMModel"], swiftSettings: strict),
        .testTarget(name: "MacVMModelTests", dependencies: ["MacVMModel"], swiftSettings: strict),
        .testTarget(name: "MacVMEngineTests", dependencies: ["MacVMEngine", "MacVMModel"], swiftSettings: strict),
        .testTarget(name: "MacVMCLITests", dependencies: ["MacVMModel"], swiftSettings: strict),
    ]
)
