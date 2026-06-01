import Foundation
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct SwitchboardMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        FeatureFlagsMacro.self,
        FlagKeyMacro.self,
    ]
}

// MARK: - @FeatureFlags

public struct FeatureFlagsMacro: MemberMacro, ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let properties = FlagProperty.parse(declaration, attribute: node, diagnose: { context.diagnose($0) }) else {
            return []
        }

        let access = accessPrefix(of: declaration)

        let definitionEntries = properties.map { property in
            """
                FlagDefinition(
                    key: \(StringLiteralExprSyntax(content: property.key)),
                    description: \(StringLiteralExprSyntax(content: property.description)),
                    defaultValue: (\(property.defaultValue) as \(property.type)).flagRawValue,
                    options: FlagDefinition.options(for: \(property.type).self)
                )
            """
        }
        let definitions: DeclSyntax = """
            \(raw: access)static let definitions: [FlagDefinition] = [
            \(raw: definitionEntries.joined(separator: ",\n"))
            ]
            """

        let assignments = properties.map { property in
            "    self.\(property.name) = resolver.value(for: \(StringLiteralExprSyntax(content: property.key)), default: \(property.defaultValue) as \(property.type))"
        }
        let resolvingInit: DeclSyntax = """
            \(raw: access)init(resolver: FlagResolver) {
            \(raw: assignments.joined(separator: "\n"))
            }
            """

        let defaultInit: DeclSyntax = """
            \(raw: access)init() {}
            """

        return [definitions, resolvingInit, defaultInit]
    }

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Diagnostics are reported once, by the member expansion.
        guard !protocols.isEmpty,
              FlagProperty.parse(declaration, attribute: node, diagnose: { _ in }) != nil
        else { return [] }

        let conformance: DeclSyntax = "extension \(type.trimmed): FeatureFlagContainer {}"
        guard let extensionDecl = conformance.as(ExtensionDeclSyntax.self) else { return [] }
        return [extensionDecl]
    }

    private static func accessPrefix(of declaration: some DeclGroupSyntax) -> String {
        for modifier in declaration.modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}

// MARK: - @FlagKey

/// A marker read by `@FeatureFlags`. Generates nothing on its own.
public struct FlagKeyMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if FlagProperty.stringArgument(of: node) == nil {
            context.diagnose(Diagnostic(node: node, message: FlagDiagnostic.flagKeyNeedsLiteral))
        }
        return []
    }
}

// MARK: - Parsing

struct FlagProperty {
    let name: String
    let key: String
    let type: String
    let defaultValue: String
    let description: String

    /// Returns `nil` (after reporting diagnostics) if the declaration can't be expanded.
    static func parse(
        _ declaration: some DeclGroupSyntax,
        attribute: AttributeSyntax,
        diagnose: (Diagnostic) -> Void
    ) -> [FlagProperty]? {
        guard declaration.is(StructDeclSyntax.self) else {
            diagnose(Diagnostic(node: attribute, message: FlagDiagnostic.notAStruct))
            return nil
        }

        var properties: [FlagProperty] = []
        var isValid = true

        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }

            let isStatic = variable.modifiers.contains {
                $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class)
            }
            if isStatic { continue }

            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                // Computed properties are left alone.
                if binding.accessorBlock != nil { continue }

                if variable.bindingSpecifier.tokenKind == .keyword(.let) {
                    diagnose(Diagnostic(node: variable.bindingSpecifier, message: FlagDiagnostic.letProperty))
                    isValid = false
                    continue
                }
                guard let type = binding.typeAnnotation?.type else {
                    diagnose(Diagnostic(node: binding.pattern, message: FlagDiagnostic.missingType))
                    isValid = false
                    continue
                }
                guard let defaultValue = binding.initializer?.value else {
                    diagnose(Diagnostic(node: binding.pattern, message: FlagDiagnostic.missingDefault))
                    isValid = false
                    continue
                }

                let name = identifier.identifier.trimmedDescription
                properties.append(FlagProperty(
                    name: name,
                    key: customKey(of: variable) ?? name.trimmingCharacters(in: CharacterSet(charactersIn: "`")),
                    type: type.trimmedDescription,
                    defaultValue: defaultValue.trimmedDescription,
                    description: docComment(of: variable)
                ))
            }
        }

        return isValid ? properties : nil
    }

    private static func customKey(of variable: VariableDeclSyntax) -> String? {
        for element in variable.attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "FlagKey"
            else { continue }
            return stringArgument(of: attribute)
        }
        return nil
    }

    static func stringArgument(of attribute: AttributeSyntax) -> String? {
        guard case .argumentList(let arguments) = attribute.arguments,
              let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              case .stringSegment(let segment) = literal.segments.first
        else { return nil }
        return segment.content.text
    }

    private static func docComment(of variable: VariableDeclSyntax) -> String {
        var lines: [String] = []
        for piece in variable.leadingTrivia {
            switch piece {
            case .docLineComment(let text):
                lines.append(String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            case .docBlockComment(let text):
                let body = text.dropFirst(3).dropLast(2)
                lines.append(
                    contentsOf: body.split(separator: "\n").map {
                        $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*")))
                    }
                )
            default:
                continue
            }
        }
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Diagnostics

enum FlagDiagnostic: String, DiagnosticMessage {
    case notAStruct
    case letProperty
    case missingType
    case missingDefault
    case flagKeyNeedsLiteral

    var message: String {
        switch self {
        case .notAStruct:
            "@FeatureFlags can only be applied to a struct"
        case .letProperty:
            "Feature flags must be declared with 'var'"
        case .missingType:
            "Feature flags need an explicit type annotation, e.g. 'var isEnabled: Bool = false'"
        case .missingDefault:
            "Feature flags need a default value"
        case .flagKeyNeedsLiteral:
            "@FlagKey requires a string literal"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "Switchboard", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}
