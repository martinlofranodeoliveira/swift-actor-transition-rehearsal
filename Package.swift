// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "actor-transition-rehearsal",
    products: [
        .library(name: "ActorTransitionRehearsal", targets: ["ActorTransitionRehearsal"]),
        .executable(name: "actor-transition-rehearsal", targets: ["RehearsalCLI"])
    ],
    targets: [
        .target(name: "ActorTransitionRehearsal"),
        .executableTarget(name: "RehearsalCLI", dependencies: ["ActorTransitionRehearsal"], path: "Sources/RehearsalCLI"),
        .testTarget(name: "ActorTransitionRehearsalTests", dependencies: ["ActorTransitionRehearsal"])
    ],
    swiftLanguageModes: [.v6]
)
