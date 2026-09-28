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
        /// Element and `#text` children, in document order.
        var children: [Node] = []
        /// Only set on `#text` nodes. Keeping text as its own child (instead of
        /// appending it to the parent) is what keeps
        /// `<td>周三 第1-2节 <span>1-16周</span> 仙Ⅱ-304</td>` in reading order.
        var text: String = ""

        static let textTag = "#text"

        init(tag: String, attributes: [String: String] = [:]) {
            self.tag = tag
            self.attributes = attributes
        }

        init(text: String) {
            self.tag = Node.textTag
            self.attributes = [:]
            self.text = text
        }

        var isText: Bool { tag == Node.textTag }

        /// Element children only.
        var elementChildren: [Node] { children.filter { !$0.isText } }

        var className: String { attributes["class"] ?? "" }

        func classNames() -> [String] {
            className.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        }

        func hasClass(_ name: String) -> Bool { classNames().contains(name) }

        /// Direct children with the given tag, plus descendants when the tag is
        /// not an immediate child (the 教务 markup nests tables loosely).
        func descendants(withTag tag: String) -> [Node] {
            var result: [Node] = []
            for child in elementChildren {
                if child.tag == tag { result.append(child) }
                result.append(contentsOf: child.descendants(withTag: tag))
            }
            return result
        }

        func descendants(withClass name: String) -> [Node] {
            var result: [Node] = []
            for child in elementChildren {
                if child.hasClass(name) { result.append(child) }
                result.append(contentsOf: child.descendants(withClass: name))
            }
            return result
        }

        /// All descendant elements, document order.
        var allElements: [Node] {
            var result: [Node] = []
            for child in elementChildren {
                result.append(child)
                result.append(contentsOf: child.allElements)
            }
            return result
        }

        /// Concatenated text, with `<br>` preserved as a newline.
        var plainText: String {
            if isText { return text }
            var value = ""
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
            for child in elementChildren {
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

    /// Deepest nesting kept. Real 教务 pages stay far below this; a page that
    /// nests deeper has its extra levels flattened into the deepest element, so
    /// the recursive walkers above cannot run out of stack.
    static let maxDepth = 256

    /// Opening one of these closes the listed open elements first, as browsers
    /// do for `<td>a<td>b` or `<li>a<li>b`. The search stops at the boundary
    /// tags so a nested table or list does not close its parent's cells.
    private static let implicitClose: [String: (closes: Set<String>, boundary: Set<String>)] = {
        let cell = (closes: Set(["td", "th"]), boundary: Set(["tr", "table", "tbody", "thead", "tfoot"]))
        let row = (closes: Set(["td", "th", "tr"]), boundary: Set(["table", "tbody", "thead", "tfoot"]))
        let section = (closes: Set(["td", "th", "tr", "tbody", "thead", "tfoot"]), boundary: Set(["table"]))
        let item = (closes: Set(["li"]), boundary: Set(["ul", "ol", "td", "th", "table"]))
        let option = (closes: Set(["option"]), boundary: Set(["select", "datalist", "optgroup"]))
        let paragraph = (closes: Set(["p"]), boundary: Set(["td", "th", "table", "li", "div", "button"]))
        var map: [String: (closes: Set<String>, boundary: Set<String>)] = [
            "td": cell, "th": cell, "tr": row,
            "tbody": section, "thead": section, "tfoot": section,
            "li": item, "option": option
        ]
        for tag in ["p", "div", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6",
                    "pre", "form", "section", "blockquote", "dl"] where map[tag] == nil {
            map[tag] = paragraph
        }
        return map
    }()

    private func build(scanner: Scanner, parent: Node) {
        var stack: [Node] = [parent]
        func appendText(_ raw: String) {
            guard !raw.isEmpty else { return }
            stack[stack.count - 1].children.append(Node(text: LightHTML.decodeEntities(raw)))
        }
        while !scanner.isAtEnd {
            // Text up to the next tag.
            if let text = scanner.scanUpToString("<") {
                appendText(text)
                continue
            }
            guard scanner.scanString("<") != nil else { break }
            // `<` not followed by a tag name, `/`, `!` or `?` is text ("1 < 2"), as in a browser.
            guard scanner.currentIndex < scanner.string.endIndex,
                  case let next = scanner.string[scanner.currentIndex],
                  next.isLetter || next == "/" || next == "!" || next == "?" else {
                appendText("<")
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
                let name = LightHTML.tagName(in: scanner.scanUpToString(">") ?? "").name
                _ = scanner.scanString(">")
                // Pop to the nearest matching open tag.
                if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 {
                    stack.removeSubrange(index..<stack.count)
                }
                continue
            }

            let (rawTag, attributeText) = LightHTML.tagName(in: scanner.scanUpToString(">") ?? "")
            _ = scanner.scanString(">")
            guard !rawTag.isEmpty else { continue }

            if let rule = LightHTML.implicitClose[rawTag] {
                // Pop up to and including the *outermost* ancestor this tag closes,
                // as browsers do: `<td>a<td>b` closes the cell, `<tr>` closes its
                // cells and the row. The walk stops at a boundary tag, so a nested
                // table never closes its parent's cells.
                var index = stack.count - 1
                var target: Int?
                while index > 0, !rule.boundary.contains(stack[index].tag) {
                    if rule.closes.contains(stack[index].tag) { target = index }
                    index -= 1
                }
                if let target { stack.removeSubrange(target..<stack.count) }
            }

            let node = Node(tag: rawTag, attributes: LightHTML.parseAttributes(attributeText))
            stack[stack.count - 1].children.append(node)
            if !LightHTML.voidTags.contains(rawTag), !attributeText.hasSuffix("/"),
               stack.count < LightHTML.maxDepth {
                stack.append(node)
            }
        }
    }

    /// Splits `td\nclass="x"` into the lowercased tag name and the attribute
    /// text. Any whitespace (or a `/`) ends the name.
    private static func tagName(in raw: String) -> (name: String, attributes: String) {
        let end = raw.firstIndex { $0.isWhitespace || $0 == "/" } ?? raw.endIndex
        return (String(raw[raw.startIndex..<end]).lowercased(), String(raw[end...]))
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

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "middot": "·", "hellip": "…", "mdash": "—", "ndash": "–"
    ]

    private static let entityPattern = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")

    /// One left-to-right pass: every entity is replaced exactly once, so
    /// `&amp;lt;` becomes the literal `&lt;` instead of `<`, and the result
    /// does not depend on dictionary iteration order. Unknown names stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = entityPattern else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = source.substring(with: match.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let value = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits)
                replacement = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[body]
            }
            result += replacement ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
