import AppKit

// MARK: - Headings and links
//
// The only formatting not built into NSTextView. Everything else (fonts,
// B/I/U, color, alignment, spacing, lists) uses AppKit's own actions, the
// inspector bar and the Lists panel. Pure attributed-string operations are
// unit-testable; menus reach the NSTextView actions with
// `NSApp.sendAction(TextFormatting.<selector>, to: nil, from: nil)`.

public enum ParagraphStyleKind: Equatable {
    case body
    /// 1 (largest) ... 3.
    case heading(Int)

    /// Menu label for the style in effect, e.g. "Body" or "H2". Compact so the
    /// formatting bar's style control stays narrow.
    public var displayName: String {
        switch self {
        case .body: "Body"
        case .heading(let level): "H\(min(max(level, 1), 3))"
        }
    }
}

public enum TextFormatting {
    /// Base body font size in points.
    public static let bodySize: CGFloat = 15

    /// Heading sizes as multiples of the body size (26 / 20 / 17 pt at the 15 pt default).
    static let headingScales: [CGFloat] = [26.0 / 15, 20.0 / 15, 17.0 / 15]
    static func headingSizes(base: CGFloat) -> [CGFloat] { headingScales.map { ($0 * base).rounded() } }
    static let inkColor = NSColor(white: 0.1, alpha: 1)

    /// Font for a paragraph style: body = system `bodySize`; headings are bold
    /// system fonts at 26 / 20 / 17 pt for levels 1 / 2 / 3 (clamped to 1...3).
    public static func font(for kind: ParagraphStyleKind, base: CGFloat = bodySize) -> NSFont {
        switch kind {
        case .body:
            return .systemFont(ofSize: base)
        case .heading(let level):
            return .boldSystemFont(ofSize: headingSizes(base: base)[min(max(level, 1), 3) - 1])
        }
    }

    /// `font(for:)`, carrying over the italic trait of `other` if it has one.
    static func font(for kind: ParagraphStyleKind, italicFrom other: NSFont?, base size: CGFloat = bodySize) -> NSFont {
        let base = font(for: kind, base: size)
        guard let other, other.fontDescriptor.symbolicTraits.contains(.italic) else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Typing attributes for a new, empty text block.
    public static var defaultAttributes: [NSAttributedString.Key: Any] {
        defaultAttributes(fontSize: bodySize)
    }

    public static func defaultAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: inkColor,
            .paragraphStyle: NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle,
        ]
    }

    // MARK: Paragraph helpers

    /// Ranges of every paragraph intersecting `range` (includes the empty
    /// trailing paragraph when `range` sits at the very end after a newline or in empty text).
    static func paragraphRanges(in text: NSString, range: NSRange) -> [NSRange] {
        let clamped = clamp(range, length: text.length)
        let expanded = text.paragraphRange(for: clamped)
        var result: [NSRange] = []
        var loc = expanded.location
        repeat {
            let pr = text.paragraphRange(for: NSRange(location: loc, length: 0))
            result.append(pr)
            if pr.upperBound <= loc { break }
            loc = pr.upperBound
        } while loc < expanded.upperBound
        return result
    }

    static func clamp(_ range: NSRange, length: Int) -> NSRange {
        let loc = min(max(range.location, 0), length)
        let end = min(max(range.upperBound, loc), length)
        return NSRange(location: loc, length: end - loc)
    }

    /// The style a font stands for: bold and at least the smallest heading size ⇒
    /// the nearest heading, else body. The caret's font is the whole story, so the
    /// formatting bar can read the current style straight from it.
    public static func paragraphStyleKind(for font: NSFont?, base: CGFloat = bodySize) -> ParagraphStyleKind {
        let headingSizes = headingSizes(base: base)
        guard let font, font.fontDescriptor.symbolicTraits.contains(.bold),
              font.pointSize >= headingSizes[2]
        else { return .body }
        var best = 0
        for (i, size) in headingSizes.enumerated()
        where abs(size - font.pointSize) < abs(headingSizes[best] - font.pointSize) {
            best = i
        }
        return .heading(best + 1)
    }

    /// The style of the paragraph containing `location` (inferred from its font:
    /// bold and ≥ heading size ⇒ heading, else body).
    public static func paragraphStyleKind(in text: NSAttributedString, at location: Int, base: CGFloat = bodySize) -> ParagraphStyleKind {
        let ns = text.string as NSString
        let length = ns.length
        guard length > 0, location >= 0, location <= length else { return .body }
        var loc = location
        if loc == length {
            if ns.character(at: length - 1) == 0x0A { return .body }
            loc = length - 1
        }
        let start = ns.paragraphRange(for: NSRange(location: loc, length: 0)).location
        return paragraphStyleKind(for: text.attribute(.font, at: start, effectiveRange: nil) as? NSFont, base: base)
    }

    /// Apply `kind` to every paragraph intersecting `range`: replaces the font
    /// (preserving italic) for the whole paragraph(s). Keeps the text itself.
    public static func apply(_ kind: ParagraphStyleKind, to storage: NSMutableAttributedString, range: NSRange,
                             base: CGFloat = bodySize) {
        guard storage.length > 0 else { return }
        let spacing: CGFloat
        switch kind {
        case .body: spacing = 0
        case .heading(let level): spacing = [10, 8, 6][min(max(level, 1), 3) - 1]
        }
        let ns = storage.string as NSString
        let paragraphs = paragraphRanges(in: ns, range: range).filter { $0.length > 0 }
        for pr in paragraphs.reversed() {
            var runs: [(NSRange, NSFont)] = []
            storage.enumerateAttribute(.font, in: pr) { value, runRange, _ in
                runs.append((runRange, font(for: kind, italicFrom: value as? NSFont, base: base)))
            }
            for (runRange, font) in runs { storage.addAttribute(.font, value: font, range: runRange) }
            let existing = storage.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (existing ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacingBefore = spacing
            storage.addAttribute(.paragraphStyle, value: style, range: pr)
        }
    }

    // MARK: Lists (Notes-style typing)
    //
    // List items use AppKit's own representation (NSTextList in the paragraph
    // style plus a "\t<marker>\t" prefix), so the inspector bar and Lists panel
    // understand them. NSTextView doesn't start, continue or end lists while
    // typing, so `listEdit` supplies those rules.

    /// An edit to perform instead of the user's keystroke.
    public struct ListEdit {
        public var range: NSRange
        public var replacement: NSAttributedString
        public var selection: NSRange
        /// Paragraph attributes for subsequent typing, when they must change.
        public var typingParagraphStyle: NSParagraphStyle?
    }

    static let listIndent: CGFloat = 28

    /// Paragraph style for a list item nested `lists.count` levels deep.
    static func listParagraphStyle(_ lists: [NSTextList], base: NSParagraphStyle?) -> NSParagraphStyle {
        let style = (base ?? .default).mutableCopy() as! NSMutableParagraphStyle
        let depth = CGFloat(max(lists.count, 1))
        style.textLists = lists
        style.headIndent = listIndent * depth
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent * (depth - 1) + 8),
                          NSTextTab(textAlignment: .left, location: listIndent * depth)]
        return style
    }

    static func plainParagraphStyle(base: NSParagraphStyle?) -> NSParagraphStyle {
        let style = (base ?? .default).mutableCopy() as! NSMutableParagraphStyle
        style.textLists = []
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        style.tabStops = NSParagraphStyle.default.tabStops
        return style
    }

    /// Length of the "\t<marker>\t" prefix of a list paragraph, or nil if `paragraph` isn't a list item.
    static func listPrefixLength(in text: NSAttributedString, paragraph: NSRange) -> Int? {
        guard paragraph.length > 0,
              let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
              !style.textLists.isEmpty else { return nil }
        let ns = text.string as NSString
        guard ns.character(at: paragraph.location) == 9 else { return nil } // "\t"
        let second = ns.range(of: "\t", options: [], range: NSRange(location: paragraph.location + 1, length: paragraph.length - 1))
        guard second.location != NSNotFound else { return nil }
        return second.location + 1 - paragraph.location
    }

    /// A paragraph's range without its trailing newline.
    static func paragraphBody(_ ns: NSString, at location: Int) -> NSRange {
        let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
        let hasNewline = paragraph.length > 0 && ns.character(at: NSMaxRange(paragraph) - 1) == 10
        return NSRange(location: paragraph.location, length: paragraph.length - (hasNewline ? 1 : 0))
    }

    /// Bullets alternate by depth like Notes (• ◦ ▪); numbered lists keep their format.
    static func nestedList(like list: NSTextList, depth: Int) -> NSTextList {
        let bullets: [NSTextList.MarkerFormat] = [.disc, .circle, .square]
        let format = bullets.contains(list.markerFormat) ? bullets[(depth - 1) % bullets.count] : list.markerFormat
        return NSTextList(markerFormat: format, options: 0)
    }

    /// Rebuilds a list paragraph (`body` with a `prefix`-long marker) at a new
    /// list nesting; an empty `lists` makes it a plain paragraph.
    static func relist(_ text: NSAttributedString, body: NSRange, prefix: Int, to lists: [NSTextList]) -> NSAttributedString {
        let base = text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle
        let content = NSMutableAttributedString(attributedString: text.attributedSubstring(
            from: NSRange(location: body.location + prefix, length: body.length - prefix)))
        guard let list = lists.last else {
            content.addAttribute(.paragraphStyle, value: plainParagraphStyle(base: base), range: NSRange(location: 0, length: content.length))
            return content
        }
        let style = listParagraphStyle(lists, base: base)
        var attrs = text.attributes(at: body.location, effectiveRange: nil)
        attrs[.paragraphStyle] = style
        attrs[.link] = nil
        let result = NSMutableAttributedString(string: "\t\(list.marker(forItemNumber: list.startingItemNumber))\t", attributes: attrs)
        content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
        result.append(content)
        return result
    }

    /// Notes-style list behavior for a keystroke replacing `range` with `replacement`:
    /// - "* ", "- ", "• " at a paragraph start → bulleted list; "3. " / "3) " → numbered list from 3.
    /// - Return in a list item → next item; Return in an empty item → outdent, or leave the list at the top level.
    /// - Backspace right after an item's marker → outdent, or back to a plain paragraph at the top level.
    /// Returns nil when the keystroke should proceed normally. Numbers are fixed up afterwards by `renumberEdits`.
    public static func listEdit(in text: NSAttributedString, range: NSRange, replacement: String,
                                typingAttributes: [NSAttributedString.Key: Any]) -> ListEdit? {
        let ns = text.string as NSString
        guard range.location <= ns.length else { return nil }
        let body = paragraphBody(ns, at: range.location)
        let prefix = listPrefixLength(in: text, paragraph: body)
        let baseStyle = (body.location < ns.length
            ? text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil)
            : typingAttributes[.paragraphStyle]) as? NSParagraphStyle

        /// Leaving the current level: one level up, or out of the list.
        func outdent(_ prefix: Int, lists: [NSTextList]) -> ListEdit {
            let replacement = relist(text, body: body, prefix: prefix, to: Array(lists.dropLast()))
            let style = replacement.length > 0
                ? replacement.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                : plainParagraphStyle(base: baseStyle)
            let caret = lists.count > 1 ? (replacement.string as NSString).range(of: "\t", options: .backwards).location + 1 : 0
            return ListEdit(range: body, replacement: replacement,
                            selection: NSRange(location: body.location + max(caret, 0), length: 0), typingParagraphStyle: style)
        }

        switch (replacement, range.length) {
        case (" ", 0) where prefix == nil:
            let lead = ns.substring(with: NSRange(location: body.location, length: range.location - body.location))
            guard let (list, number) = listTrigger(lead) else { return nil }
            let style = listParagraphStyle([list], base: baseStyle)
            var attrs = typingAttributes
            attrs[.paragraphStyle] = style
            attrs[.link] = nil
            let result = NSMutableAttributedString(string: "\t\(list.marker(forItemNumber: number))\t", attributes: attrs)
            let rest = NSMutableAttributedString(attributedString: text.attributedSubstring(
                from: NSRange(location: range.location, length: NSMaxRange(body) - range.location)))
            rest.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: rest.length))
            let caret = result.length
            result.append(rest)
            return ListEdit(range: body, replacement: result,
                            selection: NSRange(location: body.location + caret, length: 0), typingParagraphStyle: style)

        case ("\n", 0):
            guard let prefix, let style = baseStyle, let list = style.textLists.last else { return nil }
            if body.length == prefix { return outdent(prefix, lists: style.textLists) }
            var attrs = typingAttributes
            attrs[.paragraphStyle] = style
            attrs[.link] = nil
            let inserted = NSAttributedString(string: "\n\t\(list.marker(forItemNumber: list.startingItemNumber))\t", attributes: attrs)
            return ListEdit(range: range, replacement: inserted,
                            selection: NSRange(location: range.location + inserted.length, length: 0), typingParagraphStyle: style)

        case ("", 1):
            guard let prefix, let style = baseStyle, range.location == body.location + prefix - 1 else { return nil }
            return outdent(prefix, lists: style.textLists)

        default:
            return nil
        }
    }

    /// Bullet-list toggle for the paragraph at `location`: a plain paragraph
    /// becomes a bullet item, a list item (at any depth) becomes plain text.
    public static func bulletToggleEdit(in text: NSAttributedString, at location: Int,
                                        typingAttributes: [NSAttributedString.Key: Any]) -> ListEdit? {
        listToggleEdit(in: text, at: location, typingAttributes: typingAttributes, markerFormat: .disc)
    }

    /// Numbered-list toggle, exactly like `bulletToggleEdit` but items count 1, 2, 3.
    /// The marker matches what typing "1. " produces, so both routes agree.
    public static func numberToggleEdit(in text: NSAttributedString, at location: Int,
                                        typingAttributes: [NSAttributedString.Key: Any]) -> ListEdit? {
        listToggleEdit(in: text, at: location, typingAttributes: typingAttributes,
                       markerFormat: NSTextList.MarkerFormat("{decimal}."))
    }

    /// Shared toggle behind `bulletToggleEdit` and `numberToggleEdit`; `markerFormat`
    /// picks the marker a plain paragraph becomes a list item with.
    static func listToggleEdit(in text: NSAttributedString, at location: Int,
                               typingAttributes: [NSAttributedString.Key: Any],
                               markerFormat: NSTextList.MarkerFormat) -> ListEdit? {
        let ns = text.string as NSString
        guard location <= ns.length else { return nil }
        let body = paragraphBody(ns, at: location)
        let baseStyle = (body.location < ns.length
            ? text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil)
            : typingAttributes[.paragraphStyle]) as? NSParagraphStyle

        if let prefix = listPrefixLength(in: text, paragraph: body) {
            let replacement = relist(text, body: body, prefix: prefix, to: [])
            let style = replacement.length > 0
                ? replacement.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                : plainParagraphStyle(base: baseStyle)
            return ListEdit(range: body, replacement: replacement,
                            selection: NSRange(location: min(body.location + max(location - body.location - prefix, 0),
                                                             body.location + replacement.length), length: 0),
                            typingParagraphStyle: style)
        }

        let list = NSTextList(markerFormat: markerFormat, options: 0)
        let style = listParagraphStyle([list], base: baseStyle)
        var attrs = typingAttributes
        attrs[.paragraphStyle] = style
        attrs[.link] = nil
        let result = NSMutableAttributedString(string: "\t\(list.marker(forItemNumber: 1))\t", attributes: attrs)
        let rest = NSMutableAttributedString(attributedString: text.attributedSubstring(from: body))
        rest.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: rest.length))
        let prefix = result.length
        result.append(rest)
        return ListEdit(range: body, replacement: result,
                        selection: NSRange(location: location + prefix, length: 0), typingParagraphStyle: style)
    }

    /// Tab / Shift-Tab on list items: nest or un-nest every list paragraph the
    /// selection touches (top-level items can't be outdented further). Returns
    /// nil if the selection touches no list item.
    public static func listIndentEdit(in text: NSAttributedString, selection: NSRange, outdent: Bool) -> ListEdit? {
        let ns = text.string as NSString
        guard selection.location <= ns.length else { return nil }
        let affected = ns.paragraphRange(for: selection)
        var bodies: [NSRange] = []
        var location = affected.location
        repeat {
            let body = paragraphBody(ns, at: location)
            bodies.append(body)
            location = NSMaxRange(ns.paragraphRange(for: NSRange(location: location, length: 0)))
        } while location < NSMaxRange(affected)

        let result = NSMutableAttributedString()
        var changed = false
        var caretShift = 0
        for (index, body) in bodies.enumerated() {
            let original = text.attributedSubstring(from: body)
            var piece = original
            if let prefix = listPrefixLength(in: text, paragraph: body),
               let lists = (text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists,
               let last = lists.last, !(outdent && lists.count == 1) {
                let newLists = outdent ? Array(lists.dropLast()) : lists + [nestedList(like: last, depth: lists.count + 1)]
                piece = relist(text, body: body, prefix: prefix, to: newLists)
                changed = true
                if body.location <= selection.location { caretShift += piece.length - original.length }
            }
            result.append(piece)
            if index < bodies.count - 1 { result.append(text.attributedSubstring(from: NSRange(location: NSMaxRange(body), length: 1))) }
        }
        guard changed else { return nil }
        let range = NSRange(location: affected.location, length: NSMaxRange(bodies.last!) - affected.location)
        let caret = min(max(selection.location + caretShift, affected.location), affected.location + result.length)
        let style = result.length > 0 ? result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        return ListEdit(range: range, replacement: result,
                        selection: NSRange(location: caret, length: selection.length > 0 ? max(0, selection.length) : 0),
                        typingParagraphStyle: style)
    }

    /// Marker fixes that make every run of list items count up correctly, per
    /// nesting level: the first item of a run keeps its number, the rest follow.
    /// Returned in descending location order so they can be applied in sequence.
    public static func renumberEdits(in text: NSAttributedString) -> [(range: NSRange, marker: String)] {
        let ns = text.string as NSString
        var edits: [(range: NSRange, marker: String)] = []
        var counters: [Int] = []
        var location = 0
        while location < ns.length {
            let body = paragraphBody(ns, at: location)
            location = NSMaxRange(ns.paragraphRange(for: NSRange(location: location, length: 0)))
            guard let prefix = listPrefixLength(in: text, paragraph: body),
                  let lists = (text.attribute(.paragraphStyle, at: body.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists,
                  let list = lists.last
            else { counters = []; continue }
            let markerRange = NSRange(location: body.location + 1, length: prefix - 2)
            let current = ns.substring(with: markerRange)
            if counters.count > lists.count { counters.removeLast(counters.count - lists.count) }
            if counters.count < lists.count {
                while counters.count < lists.count - 1 { counters.append(1) }
                counters.append(Int(current.filter(\.isNumber)) ?? list.startingItemNumber)
            } else {
                counters[lists.count - 1] += 1
            }
            let expected = list.marker(forItemNumber: counters[lists.count - 1])
            if expected != current { edits.append((markerRange, expected)) }
        }
        return edits.reversed()
    }

    /// "*", "-", "•" → bullets; "12." / "12)" → numbers starting at 12.
    static func listTrigger(_ lead: String) -> (NSTextList, Int)? {
        if ["*", "-", "•"].contains(lead) { return (NSTextList(markerFormat: .disc, options: 0), 1) }
        guard let last = lead.last, last == "." || last == ")" else { return nil }
        let digits = lead.dropLast()
        guard (1...3).contains(digits.count), digits.allSatisfy(\.isASCII), let n = Int(digits) else { return nil }
        let list = NSTextList(markerFormat: NSTextList.MarkerFormat("{decimal}\(last)"), options: 0)
        list.startingItemNumber = n
        return (list, n)
    }

    // MARK: Links

    /// Add `url` as `.link` to `range`; if `range` is empty, insert the URL's
    /// absolute string at `range.location` and link it. Returns the linked range.
    @discardableResult
    public static func addLink(_ url: URL, to storage: NSMutableAttributedString, range: NSRange) -> NSRange {
        let clamped = clamp(range, length: storage.length)
        if clamped.length > 0 {
            storage.addAttribute(.link, value: url, range: clamped)
            return clamped
        }
        var attrs: [NSAttributedString.Key: Any]
        if clamped.location > 0 {
            attrs = storage.attributes(at: clamped.location - 1, effectiveRange: nil)
        } else if storage.length > 0 {
            attrs = storage.attributes(at: 0, effectiveRange: nil)
        } else {
            attrs = defaultAttributes
        }
        attrs[.link] = url
        let text = url.absoluteString
        storage.insert(NSAttributedString(string: text, attributes: attrs), at: clamped.location)
        return NSRange(location: clamped.location, length: (text as NSString).length)
    }

    /// Lenient URL parsing: "example.com" → https://example.com; nil if not URL-like.
    public static func url(from string: String) -> URL? {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if s.lowercased().hasPrefix("mailto:") {
            return s.count > "mailto:".count ? URL(string: s) : nil
        }
        guard s.contains(".") else { return nil }
        let full = s.contains("://") ? s : "https://" + s
        guard let url = URL(string: full), let host = url.host, !host.isEmpty,
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }

    // MARK: Selectors for menus

    public static let heading1Selector = #selector(NSTextView.formatHeading1(_:))
    public static let heading2Selector = #selector(NSTextView.formatHeading2(_:))
    public static let heading3Selector = #selector(NSTextView.formatHeading3(_:))
    public static let bodySelector = #selector(NSTextView.formatBody(_:))
    public static let addLinkSelector = #selector(NSTextView.promptAddLink(_:))
    public static let boldSelector = #selector(NSTextView.toggleBoldTrait(_:))
    public static let italicSelector = #selector(NSTextView.toggleItalicTrait(_:))
    public static let biggerSelector = #selector(NSTextView.makeFontBigger(_:))
    public static let smallerSelector = #selector(NSTextView.makeFontSmaller(_:))
    public static let bulletListSelector = #selector(NSTextView.toggleBulletList(_:))
    public static let numberListSelector = #selector(NSTextView.toggleNumberList(_:))
}

// MARK: - Responder-chain actions
//
// Each wraps the pure operation in shouldChangeText/didChangeText so it is
// undoable inside the text view and notifies its delegate.

public extension NSTextView {
    @objc func formatHeading1(_ sender: Any?) { applyParagraphKind(.heading(1)) }
    @objc func formatHeading2(_ sender: Any?) { applyParagraphKind(.heading(2)) }
    @objc func formatHeading3(_ sender: Any?) { applyParagraphKind(.heading(3)) }
    @objc func formatBody(_ sender: Any?) { applyParagraphKind(.body) }

    @objc func toggleBulletList(_ sender: Any?) { toggleList(numbered: false) }
    @objc func toggleNumberList(_ sender: Any?) { toggleList(numbered: true) }

    /// Sets the point size of the selection, or the typing attributes at a bare
    /// caret, keeping the font's bold / italic traits. Undoable like the other
    /// formatting actions (a typed size arrives as the same edit as B / I / U).
    @objc func setEditingFontSize(_ size: CGFloat) {
        guard isEditable, let storage = textStorage, size.isFinite, size > 0 else { return }
        let range = selectedRange()
        let current = (range.length > 0 && range.location < storage.length
            ? storage.attribute(.font, at: range.location, effectiveRange: nil)
            : typingAttributes[.font]) as? NSFont
        let base = current ?? NSFont.systemFont(ofSize: size)
        let font = NSFont(descriptor: base.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
        guard range.length > 0 else {
            typingAttributes[.font] = font
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: range)
        storage.endEditing()
        didChangeText()
    }

    // NSFontManager reads the trait / size action from its sender's tag, so
    // these hand it a tagged item; it then sends changeFont: back to this view.
    @objc func toggleBoldTrait(_ sender: Any?) { toggleFontTrait(.boldFontMask) }
    @objc func toggleItalicTrait(_ sender: Any?) { toggleFontTrait(.italicFontMask) }
    @objc func makeFontBigger(_ sender: Any?) { modifyFontSize(.sizeUpFontAction) }
    @objc func makeFontSmaller(_ sender: Any?) { modifyFontSize(.sizeDownFontAction) }

    /// Shows a small sheet (NSAlert with a text field) asking for a URL, then
    /// links the selection (or inserts the URL). No-op if not editable.
    @objc func promptAddLink(_ sender: Any?) {
        guard isEditable, textStorage != nil else { return }
        let target = selectedRange()
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Enter a web address or email link."
        alert.addButton(withTitle: "Add Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let url = TextFormatting.url(from: field.stringValue) else {
                NSSound.beep()
                return
            }
            self.insertLink(url, range: target)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

// MARK: - Implementation

private extension NSTextView {
    /// Shared body for `toggleBulletList` / `toggleNumberList`.
    func toggleList(numbered: Bool) {
        guard isEditable, let storage = textStorage else { return }
        let location = selectedRange().location
        let edit = numbered
            ? TextFormatting.numberToggleEdit(in: storage, at: location, typingAttributes: typingAttributes)
            : TextFormatting.bulletToggleEdit(in: storage, at: location, typingAttributes: typingAttributes)
        guard let edit else { return }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement.string) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        setSelectedRange(edit.selection)
        if let style = edit.typingParagraphStyle { typingAttributes[.paragraphStyle] = style }
        didChangeText()
    }

    /// The default font size paragraph styles scale from; the owning block's setting.
    var bodySize: CGFloat { (delegate as? TextBlockView)?.defaultFontSize ?? TextFormatting.bodySize }

    func applyParagraphKind(_ kind: ParagraphStyleKind) {
        guard isEditable, let storage = textStorage else { return }
        let selection = selectedRange()
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: TextFormatting.clamp(selection, length: ns.length))
        if paragraph.length > 0 {
            guard shouldChangeText(in: paragraph, replacementString: nil) else { return }
            storage.beginEditing()
            TextFormatting.apply(kind, to: storage, range: paragraph, base: bodySize)
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        typing[.font] = TextFormatting.font(for: kind, italicFrom: typing[.font] as? NSFont, base: bodySize)
        let style = ((typing[.paragraphStyle] as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
        switch kind {
        case .body: style.paragraphSpacingBefore = 0
        case .heading(let level): style.paragraphSpacingBefore = [10, 8, 6][min(max(level, 1), 3) - 1]
        }
        typing[.paragraphStyle] = style
        typingAttributes = typing
        setSelectedRange(TextFormatting.clamp(selection, length: storage.length))
    }

    func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        let font = range.length > 0 && range.location < storage.length
            ? storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            : typingAttributes[.font] as? NSFont
        let manager = NSFontManager.shared
        let item = NSMenuItem()
        item.tag = Int(trait.rawValue)
        if let font, manager.traits(of: font).contains(trait) {
            manager.removeFontTrait(item)
        } else {
            manager.addFontTrait(item)
        }
    }

    func modifyFontSize(_ action: NSFontAction) {
        guard isEditable else { return }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        NSFontManager.shared.modifyFont(item)
    }

    func insertLink(_ url: URL, range: NSRange) {
        guard isEditable, let storage = textStorage else { return }
        let target = TextFormatting.clamp(range, length: storage.length)
        let replacement: String? = target.length == 0 ? url.absoluteString : nil
        guard shouldChangeText(in: target, replacementString: replacement) else { return }
        storage.beginEditing()
        let linked = TextFormatting.addLink(url, to: storage, range: target)
        storage.endEditing()
        didChangeText()
        setSelectedRange(NSRange(location: linked.upperBound, length: 0))
        var typing = typingAttributes
        typing[.link] = nil
        typingAttributes = typing
    }
}
