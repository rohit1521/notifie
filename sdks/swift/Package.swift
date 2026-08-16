// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notifie",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "Notifie", targets: ["Notifie"]),
        .executable(name: "notifie-example", targets: ["NotifieExample"])
    ],
    targets: [
        .target(
            name: "Notifie",
            path: "Sources/Notifie"
        ),
        // Exercises the real SDK against a running ingest API. Used by the
        // repository's end-to-end check, not shipped to consumers.
        .executableTarget(
            name: "NotifieExample",
            dependencies: ["Notifie"],
            path: "Sources/NotifieExample"
        ),
        .testTarget(
            name: "NotifieTests",
            dependencies: ["Notifie"],
            path: "Tests/NotifieTests"
        )
    ]
)
