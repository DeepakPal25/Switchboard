// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Switchboard", targets: ["Switchboard"]),
        .library(name: "SwitchboardUI", targets: ["SwitchboardUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"603.0.0"),
    ],
    targets: [
        .macro(
            name: "SwitchboardMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(name: "Switchboard", dependencies: ["SwitchboardMacros"]),
        .target(name: "SwitchboardUI", dependencies: ["Switchboard"]),
        .testTarget(name: "SwitchboardTests", dependencies: ["Switchboard"]),
        .testTarget(
            name: "SwitchboardMacrosTests",
            dependencies: [
                "SwitchboardMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
