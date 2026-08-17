// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Notifie",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Notifie", targets: ["Notifie"]),
    ],
    targets: [
        .target(
            name: "Notifie",
            path: "sdks/swift/Sources/Notifie"
        ),
    ]
)
