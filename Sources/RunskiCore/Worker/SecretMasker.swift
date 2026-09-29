import Foundation

/// Replaces secret values (and their common encodings) with `***` in log output.
public final class SecretMasker: @unchecked Sendable {
    private var values: [String] = []
    private var regexes: [NSRegularExpression] = []
    private let lock = NSLock()

    public init() {}

    public func add(_ raw: String) {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var forms = Set([v])
        for line in v.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { forms.insert(t) }
        }
        forms.insert(Data(v.utf8).base64EncodedString())
        if v.utf8.count > 1 { forms.insert(Data(v.utf8.dropFirst()).base64EncodedString()) }
        if v.utf8.count > 2 { forms.insert(Data(v.utf8.dropFirst(2)).base64EncodedString()) }
        forms.insert(ExprValue.jsonString(v).dropFirst().dropLast().description)
        forms.insert(v.replacingOccurrences(of: "\"", with: "\\\""))
        if let uri = v.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { forms.insert(uri) }
        forms.insert(v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;"))
        if v.count > 8, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            forms.insert(String(v.dropFirst().dropLast()))
        }
        lock.lock()
        for f in forms where !f.isEmpty && !values.contains(f) { values.append(f) }
        values.sort { $0.count > $1.count }   // longest first so overlaps collapse
        lock.unlock()
    }

    public func addRegex(_ pattern: String) {
        if let r = try? NSRegularExpression(pattern: pattern) {
            lock.lock(); regexes.append(r); lock.unlock()
        }
        add(pattern)
    }

    public func mask(_ line: String) -> String {
        lock.lock()
        let vals = values, res = regexes
        lock.unlock()
        var out = line
        for v in vals where out.contains(v) {
            out = out.replacingOccurrences(of: v, with: "***")
        }
        for r in res {
            out = r.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "***")
        }
        return out
    }
}

/// `::name key=value::data` workflow commands.
public struct ActionCommand {
    public let name: String
    public let properties: [String: String]
    public let data: String

    public static let registered: Set<String> = [
        "set-output", "save-state", "add-mask", "set-env", "add-path", "debug", "warning", "error", "notice",
        "group", "endgroup", "echo", "add-matcher", "remove-matcher", "stop-commands",
    ]

    /// Parse `::cmd prop=v,prop2=v2::data`. Returns nil if the line isn't a command.
    public static func parse(_ line: String, extraNames: Set<String> = []) -> ActionCommand? {
        let s = line.drop { $0 == " " || $0 == "\t" }
        guard s.hasPrefix("::") else { return nil }
        let rest = s.dropFirst(2)
        guard let end = rest.range(of: "::") else { return nil }
        let cmdInfo = String(rest[..<end.lowerBound])
        let data = String(rest[end.upperBound...])
        let name: String
        var props: [String: String] = [:]
        if let sp = cmdInfo.firstIndex(of: " ") {
            name = String(cmdInfo[..<sp])
            for pair in cmdInfo[cmdInfo.index(after: sp)...].split(separator: ",") where !pair.isEmpty {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                props[String(kv[0]).lowercased()] = unescapeProperty(String(kv[1]))
            }
        } else {
            name = cmdInfo
        }
        guard registered.contains(name) || extraNames.contains(name) else { return nil }
        return ActionCommand(name: name, properties: props, data: unescapeData(data))
    }

    static func unescapeProperty(_ s: String) -> String {
        s.replacingOccurrences(of: "%0D", with: "\r").replacingOccurrences(of: "%0A", with: "\n")
         .replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%2C", with: ",")
         .replacingOccurrences(of: "%25", with: "%")
    }

    static func unescapeData(_ s: String) -> String {
        s.replacingOccurrences(of: "%0D", with: "\r").replacingOccurrences(of: "%0A", with: "\n")
         .replacingOccurrences(of: "%25", with: "%")
    }
}

/// `GITHUB_ENV` / `GITHUB_OUTPUT` / `GITHUB_STATE` key-value file format (with `<<EOF` heredocs).
public enum EnvFile {
    public struct FormatError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func parse(_ content: String) throws -> [(String, String)] {
        var out: [(String, String)] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty { i += 1; continue }
            let eq = line.range(of: "=")
            let heredoc = line.range(of: "<<")
            if let eq, heredoc == nil || eq.lowerBound < heredoc!.lowerBound {
                out.append((String(line[..<eq.lowerBound]), String(line[eq.upperBound...])))
                i += 1
            } else if let heredoc {
                let name = String(line[..<heredoc.lowerBound])
                let delim = String(line[heredoc.upperBound...])
                guard !name.isEmpty, !delim.isEmpty else { throw FormatError(message: "Invalid format '\(line)'") }
                var value: [String] = []
                var j = i + 1
                var found = false
                while j < lines.count {
                    if lines[j] == delim { found = true; break }
                    value.append(lines[j]); j += 1
                }
                guard found else { throw FormatError(message: "Invalid value. Matching delimiter not found '\(delim)'") }
                out.append((name, value.joined(separator: "\n")))
                i = j + 1
            } else {
                throw FormatError(message: "Invalid format '\(line)'. Name and value must be separated by '='")
            }
        }
        return out
    }
}
