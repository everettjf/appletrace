//
//  MacroExpansionTests.swift
//  Verifies the @Traced / @TraceAll / @NotTraced macros expand to the expected
//  source.
//

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

import AppleTraceMacrosPlugin

private let testMacros: [String: Macro.Type] = [
    "Traced": TracedMacro.self,
    "TraceAll": TraceAllMacro.self,
    "NotTraced": NotTracedMacro.self,
]

final class MacroExpansionTests: XCTestCase {
    func testTracedWrapsFreeFunction() {
        assertMacroExpansion(
            """
            @Traced
            func loadConfig() {
                work()
            }
            """,
            expandedSource: """
            func loadConfig() {
                AppleTrace._tracedBegin("loadConfig()")
                defer {
                    AppleTrace._tracedEnd("loadConfig()")
                }
                work()
            }
            """,
            macros: testMacros
        )
    }

    func testTracedWrapsThrowingBodyWithReturnAndLabels() {
        assertMacroExpansion(
            """
            @Traced
            func value(for key: String, _ fallback: Int) throws -> Int {
                return try compute()
            }
            """,
            expandedSource: """
            func value(for key: String, _ fallback: Int) throws -> Int {
                AppleTrace._tracedBegin("value(for:_:)")
                defer {
                    AppleTrace._tracedEnd("value(for:_:)")
                }
                return try compute()
            }
            """,
            macros: testMacros
        )
    }

    func testTracedQualifiesNameWithEnclosingTypes() {
        assertMacroExpansion(
            """
            struct Feed {
                enum Loader {
                    @Traced
                    static func load() {
                    }
                }
            }
            extension Feed.Loader {
                @Traced
                func reload(force: Bool) {
                }
            }
            """,
            expandedSource: """
            struct Feed {
                enum Loader {
                    static func load() {
                        AppleTrace._tracedBegin("Feed.Loader.load()")
                        defer {
                            AppleTrace._tracedEnd("Feed.Loader.load()")
                        }
                    }
                }
            }
            extension Feed.Loader {
                func reload(force: Bool) {
                    AppleTrace._tracedBegin("Feed.Loader.reload(force:)")
                    defer {
                        AppleTrace._tracedEnd("Feed.Loader.reload(force:)")
                    }
                }
            }
            """,
            macros: testMacros
        )
    }

    func testTracedAsyncFunctionUsesAsyncSpan() {
        assertMacroExpansion(
            """
            actor Store {
                @Traced
                func refresh() async throws -> Int {
                    try await fetch()
                }
            }
            """,
            expandedSource: """
            actor Store {
                func refresh() async throws -> Int {
                    let __appleTraceSpanID = AppleTrace._tracedAsyncBegin("Store.refresh()")
                    defer {
                        AppleTrace._tracedAsyncEnd("Store.refresh()", __appleTraceSpanID)
                    }
                    try await fetch()
                }
            }
            """,
            macros: testMacros
        )
    }

    func testTracedCustomNameIsEscaped() {
        assertMacroExpansion(
            #"""
            @Traced("feed \"refresh\"")
            func refresh() {
            }
            """#,
            expandedSource: ##"""
            func refresh() {
                AppleTrace._tracedBegin(#"feed "refresh""#)
                defer {
                    AppleTrace._tracedEnd(#"feed "refresh""#)
                }
            }
            """##,
            macros: testMacros
        )
    }

    func testTracedRejectsNonLiteralName() {
        assertMacroExpansion(
            """
            @Traced(name)
            func refresh() {
            }
            """,
            expandedSource: """
            func refresh() {
                AppleTrace._tracedBegin("refresh()")
                defer {
                    AppleTrace._tracedEnd("refresh()")
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Traced name must be a non-empty string literal", line: 1, column: 9),
            ],
            macros: testMacros
        )
    }

    func testTraceAllStampsMethodsAndInitializersButSkipsOptOuts() {
        assertMacroExpansion(
            """
            @TraceAll
            final class FeedViewModel {
                let title = "Feed"
                init(title: String) {
                }
                func reload() {
                }
                @NotTraced
                func hot() {
                }
                @Traced("custom")
                func render(_ x: Int) -> Int {
                    x
                }
            }
            """,
            expandedSource: """
            final class FeedViewModel {
                let title = "Feed"
                init(title: String) {
                    AppleTrace._tracedBegin("FeedViewModel.init(title:)")
                    defer {
                        AppleTrace._tracedEnd("FeedViewModel.init(title:)")
                    }
                }
                func reload() {
                    AppleTrace._tracedBegin("FeedViewModel.reload()")
                    defer {
                        AppleTrace._tracedEnd("FeedViewModel.reload()")
                    }
                }
                func hot() {
                }
                func render(_ x: Int) -> Int {
                    AppleTrace._tracedBegin("custom")
                    defer {
                        AppleTrace._tracedEnd("custom")
                    }
                    x
                }
            }
            """,
            macros: testMacros
        )
    }
}
