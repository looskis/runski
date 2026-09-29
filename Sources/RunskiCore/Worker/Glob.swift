import Foundation
import CryptoKit

/// Minimal `@actions/glob`-compatible matcher: `*`, `**`, `?`, `[...]`, `!` negation,
/// `#` comments, one pattern per line. Used by the native `hashFiles()`.
public struct Glob {
    struct Pattern {
        let negate: Bool
        let regex: NSRegularExpression
        let root: String   // longest literal prefix (directory) to start walking from
    }

    let patterns: [Pattern]
    let workspace: String

    public init(patterns raw: String, workspace: String) throws {
        self.workspace = workspace
        var out: [Pattern] = []
        for var line in raw.split(separator: "\n").map({ String($0).trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty || line.hasPrefix("#") { continue }
            var negate = false
            if line.hasPrefix("!") { negate = true; line.removeFirst() }
            if line.hasPrefix("~/") { line = FileManager.default.homeDirectoryForCurrentUser.path + line.dropFirst(1) }
            if !line.hasPrefix("/") { line = workspace + "/" + line }
            line = (line as NSString).standardizingPath
            let (regex, root) = try Glob.compile(line)
            out.append(Pattern(negate: negate, regex: regex, root: root))
        }
        patterns = out
    }

    static func compile(_ pattern: String) throws -> (NSRegularExpression, String) {
        var re = "^"
        var root = ""
        var literalSoFar = ""
        var sawGlob = false
        let segs = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (i, seg) in segs.enumerated() {
            if i > 0 { re += "/" }
            if seg == "**" {
                sawGlob = true
                // match zero or more path segments
                if i == segs.count - 1 { re += ".*" } else { re = String(re.dropLast()) + "(?:/.*)?" ; re += "(?:/)?"; }
                continue
            }
            var segRe = ""
            var j = seg.startIndex
            var segHasGlob = false
            while j < seg.endIndex {
                let c = seg[j]
                switch c {
                case "*": segRe += "[^/]*"; segHasGlob = true
                case "?": segRe += "[^/]"; segHasGlob = true
                case "[":
                    if let close = seg[j...].firstIndex(of: "]"), close > seg.index(after: j) {
                        var cls = String(seg[seg.index(after: j)..<close])
                        if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                        segRe += "[" + cls.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                        j = close
                        segHasGlob = true
                    } else {
                        segRe += "\\["
                    }
                default: segRe += NSRegularExpression.escapedPattern(for: String(c))
                }
                j = seg.index(after: j)
            }
            re += segRe
            if !sawGlob && !segHasGlob {
                literalSoFar += (i > 0 ? "/" : "") + seg
                root = literalSoFar
            } else {
                sawGlob = true
            }
        }
        re += "$"
        // Implicit descendants: a directory match includes everything under it.
        let full = "(?:" + re.dropLast() + ")(?:/.*)?$"
        return (try NSRegularExpression(pattern: full), root.isEmpty ? "/" : root)
    }

    /// All matching files (regular files only), depth-first, name-sorted, absolute paths.
    public func matches() -> [String] {
        var roots = Set<String>()
        for p in patterns where !p.negate { roots.insert(p.root) }
        var results: [String] = []
        var seen = Set<String>()
        for root in roots.sorted() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { if accept(root), !seen.contains(root) { results.append(root); seen.insert(root) }; continue }
            walk(root, into: &results, seen: &seen)
        }
        return results
    }

    private func walk(_ dir: String, into results: inout [String], seen: inout Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in entries.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let path = dir == "/" ? "/" + name : dir + "/" + name
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path), (attrs[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            if isDir.boolValue {
                walk(path, into: &results, seen: &seen)
            } else if accept(path), !seen.contains(path) {
                results.append(path); seen.insert(path)
            }
        }
    }

    func accept(_ path: String) -> Bool {
        var matched = false
        let range = NSRange(location: 0, length: (path as NSString).length)
        for p in patterns {
            if p.regex.firstMatch(in: path, range: range) != nil { matched = !p.negate }
        }
        return matched
    }
}

public enum HashFiles {
    /// SHA-256 over the concatenated per-file SHA-256 digests, hex; "" when nothing matched.
    public static func hash(patterns: String, workspace: String) throws -> String {
        let glob = try Glob(patterns: patterns, workspace: workspace)
        let prefix = workspace.hasSuffix("/") ? workspace : workspace + "/"
        var outer = SHA256()
        var any = false
        for file in glob.matches() {
            guard file.hasPrefix(prefix) else { continue }
            guard let handle = FileHandle(forReadingAtPath: file) else { continue }
            defer { try? handle.close() }
            var inner = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { inner.update(data: chunk) }
            outer.update(data: Data(inner.finalize()))
            any = true
        }
        guard any else { return "" }
        return outer.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
