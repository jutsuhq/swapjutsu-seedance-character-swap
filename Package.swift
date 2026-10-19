// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]

let package = Package(
    name: "Swapjutsu",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwapjutsuPrep", targets: ["SwapjutsuPrep"]),
        .library(name: "ComfyKit", targets: ["ComfyKit"]),
        .executable(name: "swapjutsu-prep", targets: ["swapjutsu-prep"]),
        .library(name: "SwapjutsuAgent", targets: ["SwapjutsuAgent"]),
        .library(name: "SwapjutsuDescribe", targets: ["SwapjutsuDescribe"]),
        .library(name: "SwapjutsuMLX", targets: ["SwapjutsuMLX"]),
        .executable(name: "swapjutsu-describe", targets: ["swapjutsu-describe"]),
        .library(name: "SwapjutsuMCP", targets: ["SwapjutsuMCP"]),
        // Bundled as Swapjutsu.app/Contents/Helpers/swapjutsu (project.yml). Not `swapjutsu` here: on a
        // case-insensitive disk that is the same file as the Swapjutsu executable.
        .executable(name: "swapjutsu-cli", targets: ["swapjutsu-cli"]),
        .library(name: "SwapjutsuApp", targets: ["SwapjutsuApp"]),
        .executable(name: "Swapjutsu", targets: ["Swapjutsu"]),
    ],
    // On by default. CI tests with `--disable-default-traits`: no test needs MLX, and its Metal kernels alone take
    // most of a cold build.
    traits: [
        .trait(name: "MLX", description: "The local prompt writer: MLX and its Hugging Face download."),
        .default(enabledTraits: ["MLX"]),
    ],
    dependencies: [
        // Only SwapjutsuMLX, with the MLX trait, builds these; the libraries and their tests don't.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        .target(name: "SwapjutsuPrep", swiftSettings: settings),
        .target(name: "ComfyKit", swiftSettings: settings),
        .executableTarget(name: "swapjutsu-prep", dependencies: ["SwapjutsuPrep"], swiftSettings: settings),
        .target(name: "SwapjutsuAgent", swiftSettings: settings),
        .target(name: "SwapjutsuDescribe", dependencies: ["SwapjutsuPrep"], swiftSettings: settings),
        .target(
            name: "SwapjutsuMLX",
            dependencies: [
                "SwapjutsuDescribe",
                .product(name: "MLXVLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
            ],
            swiftSettings: settings),
        .executableTarget(
            name: "swapjutsu-describe", dependencies: ["SwapjutsuDescribe", "SwapjutsuMLX"], swiftSettings: settings),
        .target(name: "SwapjutsuMCP", dependencies: ["SwapjutsuAgent", "ComfyKit"], swiftSettings: settings),
        .executableTarget(name: "swapjutsu-cli", dependencies: ["SwapjutsuMCP"], swiftSettings: settings),
        .target(
            name: "SwapjutsuApp", dependencies: ["SwapjutsuPrep", "ComfyKit", "SwapjutsuAgent", "SwapjutsuDescribe"],
            resources: [.process("Resources")],
            swiftSettings: settings),
        .executableTarget(name: "Swapjutsu", dependencies: ["SwapjutsuApp", "SwapjutsuMLX"], swiftSettings: settings),
        .testTarget(
            name: "SwapjutsuPrepTests", dependencies: ["SwapjutsuPrep"], exclude: ["Fixtures"], swiftSettings: settings),
        .testTarget(name: "ComfyKitTests", dependencies: ["ComfyKit"], swiftSettings: settings),
        .testTarget(name: "SwapjutsuAgentTests", dependencies: ["SwapjutsuAgent"], swiftSettings: settings),
        .testTarget(
            name: "SwapjutsuDescribeTests", dependencies: ["SwapjutsuDescribe", "SwapjutsuPrep"],
            swiftSettings: settings),
        .testTarget(
            name: "SwapjutsuMCPTests", dependencies: ["SwapjutsuMCP", "SwapjutsuAgent", "ComfyKit"],
            swiftSettings: settings),
        .testTarget(
            name: "SwapjutsuAppTests",
            dependencies: ["SwapjutsuApp", "ComfyKit", "SwapjutsuPrep", "SwapjutsuAgent", "SwapjutsuDescribe"],
            swiftSettings: settings),
    ]
)
