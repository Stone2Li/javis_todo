// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JarvisDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JarvisDomain", targets: ["JarvisDomain"]),
        .executable(name: "domain-fixtures", targets: ["DomainFixtures"])
    ],
    targets: [
        .target(name: "JarvisDomain"),
        .executableTarget(name: "DomainFixtures", dependencies: ["JarvisDomain"]),
        .testTarget(name: "JarvisDomainTests", dependencies: ["JarvisDomain"])
    ]
)
