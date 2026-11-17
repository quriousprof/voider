import Foundation

/// A value in the TOML subset Voider understands.
enum TOMLValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([TOMLValue])
}

/// Parsed document: top-level keys plus one level of `[table]` sections.
struct TOMLDocument {
    var root: [String: TOMLValue] = [:]
    var tables: [String: [String: TOMLValue]] = [:]
}

struct TOMLError: LocalizedError {
    let line: Int
    let message: String

    var errorDescription: String? { "line \(line): \(message)" }
}

/// Minimal TOML parser: comments, `[tables]`, `key = value` with strings, integers,
/// booleans and (possibly multi-line) arrays. Enough for voider.toml, no dependencies.
enum TOMLParser {
    static func parse(_ text: String) throws -> TOMLDocument {
        var doc = TOMLDocument()
        var currentTable: String?
        // Accumulates a multi-line array until its brackets balance.
        var pending: (key: String, value: String, line: Int)?

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)

            if var current = pending {
                current.value += " " + line
                if bracketsBalanced(current.value) {
                    store(try parseValue(current.value, line: current.line), key: current.key, table: currentTable, in: &doc)
                    pending = nil
                } else {
                    pending = current
                }
                continue
            }

            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw TOMLError(line: lineNumber, message: "unterminated table header") }
                let name = try parseKey(String(line.dropFirst().dropLast()), line: lineNumber)
                currentTable = name
                doc.tables[name] = doc.tables[name] ?? [:]
                continue
            }

            guard let equals = indexOfEquals(in: line) else {
                throw TOMLError(line: lineNumber, message: "expected `key = value`")
            }
            let key = try parseKey(String(line[..<equals]), line: lineNumber)
            let valueText = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)

            if valueText.hasPrefix("["), !bracketsBalanced(valueText) {
                pending = (key, valueText, lineNumber)
                continue
            }
            store(try parseValue(valueText, line: lineNumber), key: key, table: currentTable, in: &doc)
        }

        if let pending {
            throw TOMLError(line: pending.line, message: "unterminated array")
        }
        return doc
    }

    // MARK: - Helpers

    private static func store(_ value: TOMLValue, key: String, table: String?, in doc: inout TOMLDocument) {
        if let table {
            doc.tables[table, default: [:]][key] = value
        } else {
            doc.root[key] = value
        }
    }

    private static func parseKey(_ text: String, line: Int) throws -> String {
        let key = text.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { throw TOMLError(line: line, message: "empty key") }
        if key.hasPrefix("\"") || key.hasPrefix("'") { return try parseString(key, line: line) }
        return key
    }

    private static func parseValue(_ text: String, line: Int) throws -> TOMLValue {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") || text.hasPrefix("'") {
            return .string(try parseString(text, line: line))
        }
        if text.hasPrefix("[") {
            guard text.hasSuffix("]") else { throw TOMLError(line: line, message: "unterminated array") }
            let items = try splitTopLevel(String(text.dropFirst().dropLast()))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } // allows trailing commas
                .map { try parseValue($0, line: line) }
            return .array(items)
        }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if let int = Int(text.replacingOccurrences(of: "_", with: "")) { return .int(int) }
        throw TOMLError(line: line, message: "unsupported value `\(text)`")
    }

    /// Parses a basic (`"..."`, with escapes) or literal (`'...'`) string that spans the whole input.
    private static func parseString(_ text: String, line: Int) throws -> String {
        guard let quote = text.first, text.count >= 2, text.last == quote else {
            throw TOMLError(line: line, message: "unterminated string")
        }
        let body = String(text.dropFirst().dropLast())
        if quote == "'" { return body }

        var result = ""
        var escaping = false
        for char in body {
            if escaping {
                switch char {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"", "\\": result.append(char)
                default: throw TOMLError(line: line, message: "unsupported escape `\\\(char)`")
                }
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                result.append(char)
            }
        }
        return result
    }

    /// Removes a trailing `# comment`, ignoring `#` inside strings.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaping = false
        for index in line.indices {
            let char = line[index]
            if let q = quote {
                if escaping { escaping = false }
                else if char == "\\", q == "\"" { escaping = true }
                else if char == q { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func indexOfEquals(in line: String) -> String.Index? {
        var quote: Character?
        var escaping = false
        for index in line.indices {
            let char = line[index]
            if let q = quote {
                if escaping { escaping = false }
                else if char == "\\", q == "\"" { escaping = true }
                else if char == q { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "=" {
                return index
            }
        }
        return nil
    }

    private static func bracketsBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaping = false
        for char in text {
            if let q = quote {
                if escaping { escaping = false }
                else if char == "\\", q == "\"" { escaping = true }
                else if char == q { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "[" {
                depth += 1
            } else if char == "]" {
                depth -= 1
            }
        }
        return depth <= 0
    }

    /// Splits on commas that are outside strings and nested arrays.
    private static func splitTopLevel(_ text: String) throws -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        var escaping = false
        for char in text {
            if let q = quote {
                current.append(char)
                if escaping { escaping = false }
                else if char == "\\", q == "\"" { escaping = true }
                else if char == q { quote = nil }
                continue
            }
            switch char {
            case "\"", "'":
                quote = char
                current.append(char)
            case "[":
                depth += 1
                current.append(char)
            case "]":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        parts.append(current)
        return parts
    }
}
