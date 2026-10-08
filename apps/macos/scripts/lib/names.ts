// Naming helpers shared by the schema walker and the Swift emitter.

const swiftKeywords = new Set([
  "associatedtype",
  "class",
  "deinit",
  "enum",
  "extension",
  "fileprivate",
  "func",
  "import",
  "init",
  "inout",
  "internal",
  "let",
  "open",
  "operator",
  "private",
  "precedencegroup",
  "protocol",
  "public",
  "rethrows",
  "static",
  "struct",
  "subscript",
  "typealias",
  "var",
  "break",
  "case",
  "catch",
  "continue",
  "default",
  "defer",
  "do",
  "else",
  "fallthrough",
  "for",
  "guard",
  "if",
  "in",
  "repeat",
  "return",
  "throw",
  "switch",
  "where",
  "while",
  "Any",
  "as",
  "await",
  "false",
  "is",
  "nil",
  "self",
  "Self",
  "super",
  "throws",
  "true",
  "try",
  "Type",
  "Protocol",
]);

/** Type names that would shadow standard-library/Foundation types used by generated code. */
const reservedTypeNames = new Set([
  "String",
  "Int",
  "Double",
  "Bool",
  "Array",
  "Dictionary",
  "Optional",
  "Codable",
  "Encoder",
  "Decoder",
  "Error",
  "Hashable",
  "Sendable",
  "Void",
  "Never",
  "Any",
  "Date",
  "Data",
  "URL",
  "Result",
  "Task",
  "Set",
  "Duration",
  "Process",
  "Equatable",
  "Encodable",
  "Decodable",
  "CodingKey",
  "KeyedDecodingContainer",
  "KeyedEncodingContainer",
  "Character",
  "Range",
  "Swift",
  "Foundation",
  "Sequence",
  "Collection",
  "Identifiable",
  "Comparable",
  "RawRepresentable",
  "CustomStringConvertible",
  "ExpressibleByStringLiteral",
  "JSONValue",
  "Rpc",
  "RpcSpec",
  "EmptyObject",
  "VoidValue",
  "NeverFailure",
  "LossyArray",
  "WireOption",
  "WireDefault",
  "IsoDateTime",
  "HttpSpec",
  "Http",
  "Self",
  "Type",
]);

export function tokens(s: string): string[] {
  return s.split(/[^A-Za-z0-9]+/).filter(Boolean);
}

export function pascal(s: string): string {
  return tokens(s)
    .map((t) => t[0]!.toUpperCase() + t.slice(1))
    .join("");
}

export function camel(s: string): string {
  const p = pascal(s);
  if (p === "") return "empty";
  // Keep leading acronyms readable: "URLThing" -> "urlThing", "macOS" stays "macOS".
  const m = /^[A-Z]+(?=[A-Z][a-z])/.exec(p);
  const lowered = /^[A-Z0-9]+$/.test(p)
    ? p.toLowerCase()
    : m
      ? m[0].toLowerCase() + p.slice(m[0].length)
      : p[0]!.toLowerCase() + p.slice(1);
  return /^[0-9]/.test(lowered) ? `v${lowered}` : lowered;
}

/** Valid Swift identifier for a wire key or enum case; backticked when a keyword. */
export function ident(raw: string): string {
  const id = /^[A-Za-z_][A-Za-z0-9_]*$/.test(raw) ? raw : camel(raw);
  const safe = /^[0-9]/.test(id) ? `v${id}` : id;
  return swiftKeywords.has(safe) ? `\`${safe}\`` : safe;
}

export function typeName(raw: string): string {
  const base = /^[A-Za-z][A-Za-z0-9]*$/.test(raw) ? raw : pascal(raw);
  const safe = /^[A-Za-z]/.test(base) ? base : `T${base}`;
  return reservedTypeNames.has(safe) ? `${safe}Contract` : safe;
}

export function swiftString(s: string): string {
  return JSON.stringify(s).replace(/\\u([0-9a-fA-F]{4})/g, (_m, h) => `\\u{${h}}`);
}
