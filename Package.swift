// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UniversalConverter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UniversalConverter", targets: ["UniversalConverter"]),
        .executable(name: "uconv", targets: ["uconv"]),
        .library(name: "ConverterKit", targets: ["ConverterKit"]),
    ],
    targets: [
        .target(name: "ConverterKit", path: "Sources/ConverterKit"),
        .executableTarget(name: "UniversalConverter", dependencies: ["ConverterKit"], path: "Sources/UniversalConverter"),
        .executableTarget(name: "uconv", dependencies: ["ConverterKit"], path: "Sources/uconv"),
    ]
)
