// A reader for Valve's text KeyValues format (libraryfolders.vdf, appmanifest_*.acf)

import Foundation

public indirect enum VDF: Equatable, Sendable {
    case string(String)
    case object([(key: String, value: VDF)])

    public static func == (a: VDF, b: VDF) -> Bool {
        switch (a, b) {
        case let (.string(x), .string(y)): x == y
        case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }

    /// First value under `key` (keys compare case-insensitively, as Steam does).
    public subscript(_ key: String) -> VDF? {
        guard case let .object(pairs) = self else { return nil }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var pairs: [(key: String, value: VDF)] {
        if case let .object(p) = self { return p }
        return []
    }

    /// Parses a whole file: a sequence of top-level key/value pairs.
    public static func parse(_ text: String) -> VDF {
        var scanner = Scanner(chars: Array(text.unicodeScalars))
        return .object(scanner.pairs(untilBrace: false))
    }

    struct Scanner {
        var chars: [Unicode.Scalar]
        var i = 0

        mutating func pairs(untilBrace: Bool) -> [(key: String, value: VDF)] {
            var out: [(key: String, value: VDF)] = []
            while let key = token() {
                if key == "}" { if untilBrace { break } else { continue } }
                guard let next = token() else { break }
                if next == "{" {
                    out.append((key, .object(pairs(untilBrace: true))))
                } else {
                    out.append((key, .string(next)))
                }
            }
            return out
        }

        /// The next quoted string, bare word, or brace; nil at the end.
        mutating func token() -> String? {
            while i < chars.count {
                let c = chars[i]
                if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                    while i < chars.count && chars[i] != "\n" { i += 1 }
                } else if c.properties.isWhitespace {
                    i += 1
                } else {
                    break
                }
            }
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == "{" || c == "}" { i += 1; return String(c) }
            var s = String.UnicodeScalarView()
            if c == "\"" {
                i += 1
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append(chars[i])
                        }
                    } else {
                        s.append(chars[i])
                    }
                    i += 1
                }
                i += 1
            } else {
                while i < chars.count && !chars[i].properties.isWhitespace && chars[i] != "{" && chars[i] != "}" && chars[i] != "\"" {
                    s.append(chars[i]); i += 1
                }
            }
            return String(s)
        }
    }
}
