// swift-tools-version: 6.0
import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "AppleTrace",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
    ],
    products: [
        .library(name: "AppleTrace", targets: ["AppleTrace"]),
        .library(name: "AppleTraceAuto", targets: ["AppleTraceAuto"]),
        .library(name: "AppleTraceProtocol", targets: ["AppleTraceProtocol"]),
        .library(name: "AppleTraceServer", targets: ["AppleTraceServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/johnno1962/SwiftTrace.git", from: "8.6.0"),
    ],
    targets: [
        // The existing Objective-C++ trace core, reused from the Xcode tree.
        .target(
            name: "CAppleTrace"
        ),

        // Swift surface: idiomatic wrappers + the @Traced / @TraceAll macros.
        .target(
            name: "AppleTrace",
            dependencies: ["CAppleTrace", "AppleTraceMacrosPlugin"]
        ),

        // Secondary route: zero-annotation auto-tracing by bridging the proven
        // SwiftTrace runtime hook into AppleTrace events.
        .target(
            name: "AppleTraceAuto",
            dependencies: [
                "CAppleTrace",
                .product(name: "SwiftTrace", package: "SwiftTrace"),
            ],
            // SwiftTrace's API relies on global mutable state (swizzleFactory);
            // build this thin bridge in the Swift 5 language mode to match it.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .target(
            name: "AppleTraceProtocol"
        ),

        .target(
            name: "AppleTraceServer",
            dependencies: ["AppleTrace", "AppleTraceProtocol"],
            resources: [.copy("Resources/Console")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // SwiftSyntax compiler plugin implementing the macros.
        .macro(
            name: "AppleTraceMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),

        // Runnable demo + smoke check for the SwiftTrace bridge (which an
        // XCTest bundle can't exercise — see the file header).
        .executableTarget(
            name: "AppleTraceAutoExample",
            dependencies: ["AppleTrace", "AppleTraceAuto"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "AppleTraceTests",
            dependencies: [
                "AppleTrace",
                "AppleTraceAuto",
                "AppleTraceProtocol",
                "AppleTraceServer",
                "AppleTraceMacrosPlugin",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
