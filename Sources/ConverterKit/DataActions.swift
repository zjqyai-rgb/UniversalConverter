import Foundation

// MARK: - CSV

public enum CSV {
    public static func parse(_ text: String, separator: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = chars.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    public static func write(_ rows: [[String]], separator: String = ",") -> String {
        rows.map { row in
            row.map { f in
                if separator == "\t" { return f.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                return f.contains(separator) || f.contains("\"") || f.contains("\n") || f.contains("\r")
                    ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    /// Header row → array of objects, with numbers and booleans inferred.
    public static func objects(_ rows: [[String]]) -> [[String: Any]] {
        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { r in
            var o: [String: Any] = [:]
            for (i, k) in header.enumerated() { o[k] = infer(i < r.count ? r[i] : "") }
            return o
        }
    }

    static func infer(_ s: String) -> Any {
        if s.isEmpty { return NSNull() }
        if let i = Int(s), String(i) == s { return i }
        if let d = Double(s), s.first?.isNumber == true || s.first == "-" { return d }
        if s == "true" || s == "TRUE" { return true }
        if s == "false" || s == "FALSE" { return false }
        return s
    }
}

// MARK: - YAML (emitter + practical subset parser)

public enum YAML {
    public static func emit(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let d as [String: Any]:
            if d.isEmpty { return "{}" }
            return d.keys.sorted().map { k in
                let v = d[k]!
                if isScalar(v) || isEmptyContainer(v) { return "\(pad)\(key(k)): \(scalar(v))" }
                return "\(pad)\(key(k)):\n\(emit(v, indent: indent + 1))"
            }.joined(separator: "\n")
        case let a as [Any]:
            if a.isEmpty { return "[]" }
            return a.map { v in
                if isScalar(v) || isEmptyContainer(v) { return "\(pad)- \(scalar(v))" }
                let inner = emit(v, indent: indent + 1)
                return "\(pad)- " + inner.dropFirst(pad.count + 2)
            }.joined(separator: "\n")
        default:
            return pad + scalar(value)
        }
    }

    static func isScalar(_ v: Any) -> Bool { !(v is [String: Any]) && !(v is [Any]) }
    static func isEmptyContainer(_ v: Any) -> Bool { (v as? [String: Any])?.isEmpty == true || (v as? [Any])?.isEmpty == true }

    static func key(_ k: String) -> String {
        k.range(of: #"^[A-Za-z_][A-Za-z0-9_\-. ]*$"#, options: .regularExpression) != nil && !k.hasSuffix(" ") ? k : quote(k)
    }

    static func scalar(_ v: Any) -> String {
        switch v {
        case is NSNull: return "null"
        case let d as [String: Any] where d.isEmpty: return "{}"
        case let a as [Any] where a.isEmpty: return "[]"
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let s as String:
            let reserved = ["true", "false", "null", "yes", "no", "~", ""]
            if reserved.contains(s.lowercased()) || Double(s) != nil || s.contains(": ") || s.contains(" #")
                || s.contains("\n") || s.hasPrefix(" ") || s.hasSuffix(" ")
                || "-?:,[]{}#&*!|>'\"%@`".contains(s.first!) { return quote(s) }
            return s
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let d as Data: return quote(d.base64EncodedString())
        default: return quote("\(v)")
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    // Parser: block mappings/sequences, inline [a, b] and {a: b}, quoted scalars, comments, | and > blocks.
    public static func parse(_ text: String) throws -> Any {
        var lines: [(Int, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.hasPrefix("---") || raw.hasPrefix("...") { continue }
            let stripped = stripComment(raw)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { lines.append((-1, raw)); continue }
            let indent = stripped.prefix(while: { $0 == " " }).count
            lines.append((indent, String(stripped.dropFirst(indent)).trimmingCharacters(in: .whitespaces)))
        }
        var i = 0
        func skipBlank() { while i < lines.count && lines[i].0 < 0 { i += 1 } }
        func block(_ indent: Int) throws -> Any {
            skipBlank()
            guard i < lines.count else { return NSNull() }
            if lines[i].1.hasPrefix("- ") || lines[i].1 == "-" { return try sequence(lines[i].0) }
            return try mapping(lines[i].0)
        }
        func blockScalar(_ style: String, parentIndent: Int) -> String {
            var out: [String] = []
            var baseIndent: Int? = nil
            while i < lines.count {
                let (ind, _) = lines[i]
                let raw = lines[i].0 < 0 ? "" : String(repeating: " ", count: ind) + lines[i].1
                if ind >= 0 && ind <= parentIndent { break }
                if ind >= 0 && baseIndent == nil { baseIndent = ind }
                out.append(ind < 0 ? "" : String(raw.dropFirst(baseIndent ?? 0)))
                i += 1
            }
            while out.last == "" { out.removeLast() }
            return style.hasPrefix("|") ? out.joined(separator: "\n") + "\n" : out.joined(separator: " ") + "\n"
        }
        func value(_ s: String, indent: Int) throws -> Any {
            if s.isEmpty {
                skipBlank()
                if i < lines.count && (lines[i].0 > indent || (lines[i].0 == indent && lines[i].1.hasPrefix("- "))) { return try block(lines[i].0) }
                return NSNull()
            }
            if s == "|" || s == ">" || s == "|-" || s == ">-" {
                let v = blockScalar(s, parentIndent: indent)
                return s.hasSuffix("-") ? String(v.dropLast()) : v
            }
            return inline(s)
        }
        func mapping(_ indent: Int) throws -> Any {
            var d: [String: Any] = [:]
            while true {
                skipBlank()
                guard i < lines.count, lines[i].0 == indent, !lines[i].1.hasPrefix("- ") else { break }
                let line = lines[i].1
                guard let (k, rest) = splitKey(line) else { throw ConvertError.failed("YAML: can't parse line “\(line)”") }
                i += 1
                d[k] = try value(rest, indent: indent)
            }
            return d
        }
        func sequence(_ indent: Int) throws -> Any {
            var a: [Any] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].0 == indent, lines[i].1.hasPrefix("- ") || lines[i].1 == "-" else { break }
                let item = lines[i].1 == "-" ? "" : String(lines[i].1.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let (_, _) = splitKey(item), !item.hasPrefix("\""), !item.hasPrefix("{") {
                    // "- key: value" starts a mapping at deeper indent.
                    lines[i] = (indent + 2, item)
                    a.append(try mapping(indent + 2))
                } else {
                    i += 1
                    a.append(try value(item, indent: indent))
                }
            }
            return a
        }
        return try block(0)
    }

    static func stripComment(_ s: String) -> String {
        var inS = false, inD = false
        var prev: Character = " "
        for (idx, c) in zip(s.indices, s) {
            if c == "'" && !inD { inS.toggle() }
            if c == "\"" && !inS && prev != "\\" { inD.toggle() }
            if c == "#" && !inS && !inD && (prev == " " || idx == s.startIndex) { return String(s[..<idx]) }
            prev = c
        }
        return s
    }

    static func splitKey(_ line: String) -> (String, String)? {
        var inS = false, inD = false, depth = 0
        for (idx, c) in zip(line.indices, line) {
            switch c {
            case "'" where !inD: inS.toggle()
            case "\"" where !inS: inD.toggle()
            case "[", "{": if !inS && !inD { depth += 1 }
            case "]", "}": if !inS && !inD { depth -= 1 }
            case ":" where !inS && !inD && depth == 0:
                let next = line.index(after: idx)
                if next == line.endIndex || line[next] == " " {
                    var k = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                    if (k.hasPrefix("\"") && k.hasSuffix("\"")) || (k.hasPrefix("'") && k.hasSuffix("'")), k.count >= 2 { k = String(k.dropFirst().dropLast()) }
                    return (k, String(line[next...]).trimmingCharacters(in: .whitespaces))
                }
            default: break
            }
        }
        return nil
    }

    static func inline(_ s: String) -> Any {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t").replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
        if t.hasPrefix("'") && t.hasSuffix("'") && t.count >= 2 { return String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        if t.hasPrefix("[") && t.hasSuffix("]") { return splitFlow(String(t.dropFirst().dropLast())).map { inline($0) } }
        if t.hasPrefix("{") && t.hasSuffix("}") {
            var d: [String: Any] = [:]
            for part in splitFlow(String(t.dropFirst().dropLast())) {
                if let (k, v) = splitKey(part) { d[k] = inline(v) }
            }
            return d
        }
        switch t {
        case "null", "~", "Null", "NULL": return NSNull()
        case "true", "True", "TRUE", "yes", "Yes": return true
        case "false", "False", "FALSE", "no", "No": return false
        default: break
        }
        if let n = Int(t) { return n }
        if let d = Double(t), t.rangeOfCharacter(from: .letters) == nil { return d }
        return t
    }

    static func splitFlow(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", depth = 0, inS = false, inD = false
        for c in s {
            if c == "'" && !inD { inS.toggle() }
            if c == "\"" && !inS { inD.toggle() }
            if !inS && !inD { if "[{".contains(c) { depth += 1 } else if "]}".contains(c) { depth -= 1 } }
            if c == "," && depth == 0 && !inS && !inD { parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(c) }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(cur.trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}

// MARK: - Data actions

enum DataActions {
    static func readObject(_ url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        switch url.kind {
        case .json:
            if url.ext == "jsonl" {
                let text = String(decoding: data, as: UTF8.self)
                return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
            }
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])
        case .plist: return try PropertyListSerialization.propertyList(from: data, format: nil)
        case .yaml: return try YAML.parse(String(decoding: data, as: UTF8.self))
        case .csv: return CSV.objects(CSV.parse(String(decoding: data, as: UTF8.self)))
        case .tsv: return CSV.objects(CSV.parse(String(decoding: data, as: UTF8.self), separator: "\t"))
        default: throw ConvertError.unreadable(url)
        }
    }

    /// JSON can't hold Date/Data, so make plist values JSON-safe.
    static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let d as Data: return d.base64EncodedString()
        default: return v
        }
    }

    /// Plists can't hold null.
    static func plistSafe(_ v: Any) -> Any? {
        switch v {
        case is NSNull: return nil
        case let d as [String: Any]: return d.compactMapValues(plistSafe)
        case let a as [Any]: return a.compactMap(plistSafe)
        default: return v
        }
    }

    static func json(_ v: Any, pretty: Bool = true) throws -> Data {
        var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { opts.formUnion([.prettyPrinted, .sortedKeys]) }
        return try JSONSerialization.data(withJSONObject: jsonSafe(v), options: opts)
    }

    static func table(_ v: Any) throws -> [[String]] {
        let rows: [[String: Any]]
        if let a = v as? [[String: Any]] { rows = a }
        else if let d = v as? [String: Any], let a = d.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] { rows = a }
        else if let d = v as? [String: Any] { rows = [d] }
        else if let a = v as? [Any] { return [["value"]] + a.map { [cell($0)] } }
        else { throw ConvertError.failed("Data needs to be a list of records to make a table.") }
        var keys: [String] = []
        for r in rows { for k in r.keys.sorted() where !keys.contains(k) { keys.append(k) } }
        return [keys] + rows.map { r in keys.map { r[$0].map(cell) ?? "" } }
    }

    static func cell(_ v: Any) -> String {
        switch v {
        case is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
        default:
            return (try? JSONSerialization.data(withJSONObject: jsonSafe(v), options: [.sortedKeys, .fragmentsAllowed]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\(v)"
        }
    }

    static let structured: Set<FileKind> = [.json, .plist, .yaml, .csv, .tsv]

    static func make(_ id: String, _ title: String, _ detail: String, _ symbol: String, accepts: Set<FileKind>,
                     ext: String, suffix: String? = nil, same: Set<String> = [],
                     _ body: @escaping @Sendable (URL) throws -> Data) -> FileAction {
        FileAction(id: id, title: title, detail: detail, symbol: symbol, category: .data, accepts: accepts, sameFormat: same,
                   mode: .each { url, ctx in
            let data = try body(url)
            let out = ctx.destination(for: url, ext: ext, suffix: suffix ?? (url.ext == ext ? title.lowercased() : nil))
            try data.write(to: out)
            return ActionOutput(files: [out])
        })
    }

    static var all: [FileAction] {
        [
            make("data.json", "JSON", "Convert to pretty JSON", "curlybraces", accepts: [.plist, .yaml, .csv, .tsv], ext: "json") {
                try json(try readObject($0))
            },
            make("data.yaml", "YAML", "Convert to YAML", "list.bullet.indent", accepts: [.json, .plist, .csv, .tsv], ext: "yaml") {
                Data((YAML.emit(jsonSafe(try readObject($0))) + "\n").utf8)
            },
            make("data.plist", "Plist (XML)", "Apple property list, XML", "list.bullet.rectangle", accepts: [.json, .yaml, .csv, .tsv, .plist], ext: "plist") { url in
                guard let v = plistSafe(try readObject(url)) else { throw ConvertError.failed("Nothing to convert.") }
                return try PropertyListSerialization.data(fromPropertyList: v, format: .xml, options: 0)
            },
            make("data.bplist", "Plist (Binary)", "Apple property list, binary", "list.bullet.rectangle.fill", accepts: [.json, .yaml, .plist], ext: "plist", suffix: "binary") { url in
                guard let v = plistSafe(try readObject(url)) else { throw ConvertError.failed("Nothing to convert.") }
                return try PropertyListSerialization.data(fromPropertyList: v, format: .binary, options: 0)
            },
            make("data.csv", "CSV", "Comma-separated table", "tablecells", accepts: [.json, .yaml, .plist, .tsv], ext: "csv") {
                Data(CSV.write(try table(try readObject($0))).utf8)
            },
            make("data.tsv", "TSV", "Tab-separated table", "tablecells.badge.ellipsis", accepts: [.json, .yaml, .plist, .csv], ext: "tsv") {
                Data(CSV.write(try table(try readObject($0)), separator: "\t").utf8)
            },
            make("data.mdtable", "Markdown Table", "Table as Markdown", "tablecells.fill", accepts: structured, ext: "md") { url in
                let rows = try table(try readObject(url))
                guard let head = rows.first else { return Data() }
                func esc(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
                var lines = ["| " + head.map(esc).joined(separator: " | ") + " |", "|" + head.map { _ in " --- |" }.joined()]
                lines += rows.dropFirst().map { "| " + $0.map(esc).joined(separator: " | ") + " |" }
                return Data((lines.joined(separator: "\n") + "\n").utf8)
            },
            make("data.htmltable", "HTML Table", "Styled HTML table", "tablecells", accepts: structured, ext: "html") { url in
                let rows = try table(try readObject(url))
                let head = rows.first?.map { "<th>\(Markdown.escape($0))</th>" }.joined() ?? ""
                let body = rows.dropFirst().map { "<tr>" + $0.map { "<td>\(Markdown.escape($0))</td>" }.joined() + "</tr>" }.joined(separator: "\n")
                let html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(Markdown.escape(url.lastPathComponent))</title>
                <style>body{font-family:-apple-system,sans-serif;margin:24px}table{border-collapse:collapse}th{background:#f2f2f2;position:sticky;top:0}td,th{border:1px solid #ddd;padding:6px 10px;text-align:left}tr:nth-child(even){background:#fafafa}</style>
                </head><body><table><thead><tr>\(head)</tr></thead><tbody>
                \(body)
                </tbody></table></body></html>
                """
                return Data(html.utf8)
            },
            make("data.pretty", "Pretty JSON", "Indent and sort keys", "text.alignleft", accepts: [.json], ext: "json", suffix: "pretty") {
                try json(try readObject($0))
            },
            make("data.minify", "Minify JSON", "Remove all whitespace", "arrow.right.and.line.vertical.and.arrow.left", accepts: [.json], ext: "json", suffix: "min") {
                try json(try readObject($0), pretty: false)
            },
            make("data.xmlpretty", "Pretty XML", "Re-indent XML", "chevron.left.forwardslash.chevron.right", accepts: [.xml, .plist, .svg, .html], ext: "xml", suffix: "pretty") { url in
                let opts: XMLNode.Options = url.kind == .html ? [.documentTidyHTML] : []
                let doc = try XMLDocument(contentsOf: url, options: opts)
                return doc.xmlData(options: [.nodePrettyPrint])
            },
            make("data.validate", "Validate", "Check that the data parses", "checkmark.seal", accepts: [.json, .plist, .yaml, .xml], ext: "txt") { _ in Data() }
                .replacingMode(.each { url, _ in
                    do {
                        if url.kind == .xml { _ = try XMLDocument(contentsOf: url, options: []) } else { _ = try readObject(url) }
                        return ActionOutput(message: "✓ \(url.lastPathComponent) is valid \(url.ext.uppercased())")
                    } catch {
                        let msg = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
                        throw ConvertError.failed("✗ \(url.lastPathComponent): \(msg)")
                    }
                }),
        ]
    }
}

extension FileAction {
    func replacingMode(_ mode: Mode) -> FileAction {
        var copy = FileAction(id: id, title: title, detail: detail, symbol: symbol, category: category, accepts: accepts,
                              sameFormat: sameFormat, minCount: minCount, mode: mode)
        copy.extraCondition = extraCondition
        return copy
    }
}
