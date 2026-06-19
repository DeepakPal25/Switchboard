import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(SwitchboardMacros)
import SwitchboardMacros

let testMacros: [String: any Macro.Type] = [
    "FeatureFlags": FeatureFlagsMacro.self,
    "FlagKey": FlagKeyMacro.self,
]
#endif

/// Checks that misuse produces clear compiler errors on the right line.
/// Successful expansions are covered by the runtime tests in SwitchboardTests,
/// which compile and exercise real generated code.
final class FeatureFlagsMacroDiagnosticsTests: XCTestCase {
    func testRejectsLetProperties() throws {
        #if canImport(SwitchboardMacros)
        assertMacroExpansion(
            """
            @FeatureFlags
            struct Flags {
                let isEnabled: Bool = false
            }
            """,
            expandedSource: """
            struct Flags {
                let isEnabled: Bool = false
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Feature flags must be declared with 'var'", line: 3, column: 5),
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("Macros are only supported when running tests for the host platform")
        #endif
    }

    func testRequiresTypeAnnotation() throws {
        #if canImport(SwitchboardMacros)
        assertMacroExpansion(
            """
            @FeatureFlags
            struct Flags {
                var isEnabled = false
            }
            """,
            expandedSource: """
            struct Flags {
                var isEnabled = false
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Feature flags need an explicit type annotation, e.g. 'var isEnabled: Bool = false'",
                    line: 3,
                    column: 9
                ),
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("Macros are only supported when running tests for the host platform")
        #endif
    }

    func testRequiresDefaultValue() throws {
        #if canImport(SwitchboardMacros)
        assertMacroExpansion(
            """
            @FeatureFlags
            struct Flags {
                var limit: Int
            }
            """,
            expandedSource: """
            struct Flags {
                var limit: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Feature flags need a default value", line: 3, column: 9),
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("Macros are only supported when running tests for the host platform")
        #endif
    }

    func testRejectsNonStructs() throws {
        #if canImport(SwitchboardMacros)
        assertMacroExpansion(
            """
            @FeatureFlags
            class Flags {
            }
            """,
            expandedSource: """
            class Flags {
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@FeatureFlags can only be applied to a struct", line: 1, column: 1),
            ],
            macros: testMacros
        )
        #else
        throw XCTSkip("Macros are only supported when running tests for the host platform")
        #endif
    }
}
