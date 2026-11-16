// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Holler",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "HollerCore", targets: ["HollerCore"]),
    .library(name: "HollerSpeech", targets: ["HollerSpeech"]),
    .executable(name: "holler", targets: ["holler"]),
  ],
  dependencies: [
    // Mic capture and the Dictation API client come from Blurt's engine.
    // Pinned to a commit: Blurt moves fast, and an upgrade should be a deliberate diff.
    .package(url: "https://github.com/AssemblyAI/blurt.git", revision: "479b0bdf0860f82640fb518bb791a193a98f9975")
  ],
  targets: [
    // Herdr, LLM Gateway and the assistant loop. No Blurt dependency, so it
    // stays fast to build and test.
    .target(name: "HollerCore"),
    .target(
      name: "HollerSpeech",
      dependencies: ["HollerCore", .product(name: "BlurtEngine", package: "blurt")]
    ),
    .executableTarget(name: "holler", dependencies: ["HollerCore", "HollerSpeech"]),
    // The menu-bar app. scripts/build-app.sh wraps it in "Holler.app".
    .executableTarget(
      name: "HollerApp",
      dependencies: ["HollerCore", "HollerSpeech", .product(name: "BlurtEngine", package: "blurt")]
    ),
    .testTarget(name: "HollerCoreTests", dependencies: ["HollerCore"]),
  ]
)
