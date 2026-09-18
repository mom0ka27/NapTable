import Foundation

/// A very small HTML reader.
///
/// The Flutter importers used the `html` package to walk the 教务 pages. Pulling
/// a DOM library into a SwiftUI app for two known page layouts is not worth it,
/// so this type keeps just enough of that API — nested tags with classes and
/// ordered children — for `CourseHTMLParser` to read the two tables it needs.
///
/// It is deliberately tolerant: unclosed tags, attribute quoting styles and
/// stray text all resolve to something usable, and anything it cannot make sense
/// of is dropped instead of throwing.
nonisolated struct LightHTML {
    final class Node {
        let tag: String
        let attributes: [String: String]
        var children: [Node] = []
        var text: String = ""

        init(tag: String, attributes: [String: String] = [:]) {
            self.tag = tag
            self.attributes = attributes
        }

        var className: String { attributes["class"] ?? "" }

        func classNames() -> [String] {
            className.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        }

        func hasClass(_ name: String) -> Bool { classNames().contains(name) }

        /// Direct children with the given tag, plus descendants when the tag is
        /// not an immediate child (the 教务 markup nests tables loosely).
        func descendants(withTag tag: String) -> [Node] {
            var result: [Node] = []
            for child in children {
                if child.tag == tag { result.append(child) }
                result.append(contentsOf: child.descendants(withTag: tag))
            }
            return result
        }

        func descendants(withClass name: String) -> [Node] {
            var result: [Node] = []
            for child in children {
                if child.hasClass(name) { result.append(child) }
                result.append(contentsOf: child.descendants(withClass: name))
            }
            return result
        }

        /// All descendant elements, document order.
        var allElements: [Node] {
            var result: [Node] = []
            for child in children {
                result.append(child)
                result.append(contentsOf: child.allElements)
            }
            return result
        }

        /// Concatenated text, with `<br>` preserved as a newline.
        var plainText: String {
            var value = text
            for child in children {
                if child.tag == "br" {
                    value += "\n"
                } else {
                    value += child.plainText
                }
            }
            return value
        }

        /// Text of the element with runs of whitespace collapsed, matching what
        /// `innerText` produced in the Flutter extractors.
        var trimmedText: String {
            plainText
                .replacingOccurrences(of: "\u{FFFD}", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// First `title` attribute found in this subtree.
        var firstTitle: String? {
            if let title = attributes["title"] { return title }
            for child in children {
                if let value = child.firstTitle { return value }
            }
            return nil
        }
    }

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    private static let ignoredTags: Set<String> = ["script", "style", "head", "noscript"]

    let root = Node(tag: "#document")

    init(_ html: String) {
        let normalized = LightHTML.normalized(html)
        let scanner = Scanner(string: normalized)
        scanner.charactersToBeSkipped = nil
        build(scanner: scanner, parent: root)
    }

    private init() {}

    /// Parses a fragment as if it were a page.
    static func parse(_ html: String) -> LightHTML { LightHTML(html) }

    static func parseFragment(_ html: String) -> [Node] {
        let holder = LightHTML()
        let scanner = Scanner(string: normalized(html))
        scanner.charactersToBeSkipped = nil
        holder.build(scanner: scanner, parent: holder.root)
        return holder.root.children
    }

    // MARK: Parsing

    private func build(scanner: Scanner, parent: Node) {
        var stack: [Node] = [parent]
        while !scanner.isAtEnd {
            // Text up to the next tag.
            if let text = scanner.scanUpToString("<"), !text.isEmpty {
                stack[stack.count - 1].text += LightHTML.decodeEntities(text)
                continue
            }
            guard scanner.scanString("<") != nil else {
                if let rest = scanner.scanUpToString(">") { stack[stack.count - 1].text += rest }
                if scanner.scanString(">") == nil { break }
                continue
            }
            if scanner.scanString("!--") != nil {
                _ = scanner.scanUpToString("-->")
                _ = scanner.scanString("-->")
                continue
            }
            if scanner.scanString("!") != nil || scanner.scanString("?") != nil {
                _ = scanner.scanUpToString(">")
                _ = scanner.scanString(">")
                continue
            }
            if scanner.scanString("/") != nil {
                let name = (scanner.scanUpToString(">") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                _ = scanner.scanString(">")
                // Pop to the nearest matching open tag.
                if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 {
                    stack.removeSubrange(index..<stack.count)
                }
                continue
            }

            let name = (scanner.scanUpToString(">") ?? "")
            let closeIndex = name.firstIndex(of: " ")
            let rawTag = (closeIndex.map { String(name[name.startIndex..<$0]) } ?? name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let attributeText = closeIndex.map { String(name[name.index(after: $0)...]) } ?? ""
            _ = scanner.scanString(">")
            guard !rawTag.isEmpty else { continue }

            let node = Node(tag: rawTag, attributes: LightHTML.parseAttributes(attributeText))
            stack[stack.count - 1].children.append(node)
            if !LightHTML.voidTags.contains(rawTag), !attributeText.hasSuffix("/") {
                stack.append(node)
            }
        }
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        let terminators = CharacterSet(charactersIn: " \t\n\r/")
        while !scanner.isAtEnd {
            _ = scanner.scanCharacters(from: terminators)
            guard let name = scanner.scanUpToCharacters(from: CharacterSet(charactersIn: "= \t\n\r/>")) else { break }
            var value = ""
            _ = scanner.scanCharacters(from: CharacterSet(charactersIn: " \t\n\r"))
            if scanner.scanString("=") != nil {
                _ = scanner.scanCharacters(from: CharacterSet(charactersIn: " \t\n\r"))
                if let quoted = scanner.scanString("\"") {
                    _ = quoted
                    value = scanner.scanUpToString("\"") ?? ""
                    _ = scanner.scanString("\"")
                } else if scanner.scanString("'") != nil {
                    value = scanner.scanUpToString("'") ?? ""
                    _ = scanner.scanString("'")
                } else {
                    value = scanner.scanUpToCharacters(from: terminators) ?? ""
                }
            }
            let key = name.lowercased()
            if !key.isEmpty {
                result[key] = decodeEntities(value)
            }
        }
        return result
    }

    /// `<br>` becomes a marker the text walker turns back into a newline, so the
    /// Flutter parsers' `innerHTML.replaceAll('<br>', '\n')` still works.
    /// Comments, scripts and styles are removed up front: they contain stray `<`
    /// characters that would otherwise be read as tags.
    private static func normalized(_ html: String) -> String {
        var value = html
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = removing(pattern: "<!--.*?-->", from: value, options: [.dotMatchesLineSeparators])
        value = removing(pattern: "(?is)<script\\b[^>]*>.*?</script\\s*>", from: value)
        value = removing(pattern: "(?is)<style\\b[^>]*>.*?</style\\s*>", from: value)
        value = removing(pattern: "(?is)<head\\b[^>]*>.*?</head\\s*>", from: value)
        value = replacing(pattern: "(?i)<br\\s*/?>", with: "\u{FFFD}", in: value)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        return value
    }

    private static func removing(pattern: String, from text: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func replacing(pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var value = text
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&middot;": "·",
            "&hellip;": "…", "&mdash;": "—", "&ndash;": "–"
        ]
        for (key, replacement) in named {
            value = value.replacingOccurrences(of: key, with: replacement)
        }
        guard value.contains("&#") else { return value }
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else { return value }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: value),
                  let numberRange = Range(match.range(at: 1), in: value) else { continue }
            let digits = String(value[numberRange])
            let scalarValue = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            guard let scalarValue, let scalar = Unicode.Scalar(scalarValue) else { continue }
            value.replaceSubrange(full, with: String(Character(scalar)))
        }
        return value
    }
}
