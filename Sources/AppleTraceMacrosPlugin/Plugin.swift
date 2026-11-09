//
//  Plugin.swift
//  SwiftSyntax implementation of the AppleTrace tracing macros.
//

import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@Traced` / `@Traced("name")` — a body macro that wraps the function body in
/// a trace span closed via `defer`, so it survives throws and early returns.
///
/// * The default name is the function's signature qualified by its enclosing
///   types, e.g. `FeedViewModel.reload(force:)`, so same-named methods on
///   different types stay distinct.
/// * The name is emitted as a string literal and passed as a `StaticString`,
///   so the generated code does not allocate.
/// * `async` functions get an async span (`b`/`e` with a per-call id) because
///   an `await` may resume on another thread; a section (`B`/`E`) must begin
///   and end on the same thread.
public struct TracedMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let body = declaration.body else {
            context.diagnose(Diagnostic(node: node, message: TracedDiagnostic.missingBody))
            return []
        }

        let name: String
        if let custom = try customName(from: node, in: context) {
            name = custom
        } else {
            name = qualifiedName(of: declaration, lexicalContext: context.lexicalContext)
        }
        let literal = StringLiteralExprSyntax(content: name)

        var statements: [CodeBlockItemSyntax]
        if isAsync(declaration) {
            statements = [
                "let __appleTraceSpanID = AppleTrace._tracedAsyncBegin(\(literal))",
                "defer { AppleTrace._tracedAsyncEnd(\(literal), __appleTraceSpanID) }",
            ]
        } else {
            statements = [
                "AppleTrace._tracedBegin(\(literal))",
                "defer { AppleTrace._tracedEnd(\(literal)) }",
            ]
        }
        statements.append(contentsOf: body.statements)
        return statements
    }

    /// Reads the optional `@Traced("name")` argument. Only a plain string
    /// literal is accepted, since the name must be a `StaticString`.
    static func customName(from node: AttributeSyntax, in context: some MacroExpansionContext) throws -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self), let first = arguments.first else {
            return nil
        }
        guard let literal = first.expression.as(StringLiteralExprSyntax.self),
              let value = literal.representedLiteralValue,
              !value.isEmpty else {
            context.diagnose(Diagnostic(node: first.expression, message: TracedDiagnostic.nameMustBeLiteral))
            return nil
        }
        return value
    }

    static func isAsync(_ declaration: some DeclSyntaxProtocol) -> Bool {
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return function.signature.effectSpecifiers?.asyncSpecifier != nil
        }
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            return initializer.signature.effectSpecifiers?.asyncSpecifier != nil
        }
        if let accessor = declaration.as(AccessorDeclSyntax.self) {
            return accessor.effectSpecifiers?.asyncSpecifier != nil
        }
        return false
    }

    /// `Outer.Inner.method(label:_:)`.
    static func qualifiedName(of declaration: some DeclSyntaxProtocol, lexicalContext: [Syntax]) -> String {
        let base = signatureName(of: declaration)
        let types = lexicalContext.reversed().compactMap(typeName(of:))
        return (types + [base]).joined(separator: ".")
    }

    static func signatureName(of declaration: some DeclSyntaxProtocol) -> String {
        if let function = declaration.as(FunctionDeclSyntax.self) {
            return function.name.text + parameterLabels(function.signature.parameterClause)
        }
        if let initializer = declaration.as(InitializerDeclSyntax.self) {
            let optional = initializer.optionalMark.map { $0.text } ?? ""
            return "init" + optional + parameterLabels(initializer.signature.parameterClause)
        }
        if declaration.is(DeinitializerDeclSyntax.self) {
            return "deinit"
        }
        if let accessor = declaration.as(AccessorDeclSyntax.self) {
            return accessor.accessorSpecifier.text
        }
        return "body"
    }

    static func parameterLabels(_ clause: FunctionParameterClauseSyntax) -> String {
        let labels = clause.parameters.map { parameter in
            parameter.firstName.text + ":"
        }
        return "(" + labels.joined() + ")"
    }

    static func typeName(of syntax: Syntax) -> String? {
        if let decl = syntax.as(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = syntax.as(StructDeclSyntax.self) { return decl.name.text }
        if let decl = syntax.as(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = syntax.as(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = syntax.as(ProtocolDeclSyntax.self) { return decl.name.text }
        if let decl = syntax.as(ExtensionDeclSyntax.self) {
            return decl.extendedType.trimmedDescription
        }
        return nil
    }
}

/// `@TraceAll` — a member-attribute macro that stamps `@Traced` onto every
/// method and initializer (with a body) declared directly in the type or
/// extension, skipping members already marked `@Traced` or `@NotTraced`.
public struct TraceAllMacro: MemberAttributeMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingAttributesFor member: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AttributeSyntax] {
        let attributes: AttributeListSyntax
        if let function = member.as(FunctionDeclSyntax.self), function.body != nil {
            attributes = function.attributes
        } else if let initializer = member.as(InitializerDeclSyntax.self), initializer.body != nil {
            attributes = initializer.attributes
        } else {
            return []
        }

        let alreadyHandled = attributes.contains { element in
            guard let name = element.as(AttributeSyntax.self)?.attributeName.trimmedDescription else {
                return false
            }
            return name == "Traced" || name == "NotTraced"
                || name == "AppleTrace.Traced" || name == "AppleTrace.NotTraced"
        }
        return alreadyHandled ? [] : ["@Traced"]
    }
}

/// `@NotTraced` — opts a member out of `@TraceAll`. Generates nothing.
public struct NotTracedMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

enum TracedDiagnostic: String, DiagnosticMessage {
    case missingBody
    case nameMustBeLiteral

    var message: String {
        switch self {
        case .missingBody:
            return "@Traced requires a function with a body"
        case .nameMustBeLiteral:
            return "@Traced name must be a non-empty string literal"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "AppleTraceMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity { .error }
}

@main
struct AppleTraceMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        TracedMacro.self,
        TraceAllMacro.self,
        NotTracedMacro.self,
    ]
}
