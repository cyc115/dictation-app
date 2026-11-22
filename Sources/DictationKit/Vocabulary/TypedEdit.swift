import AppKit

/// A key the edit watcher can follow, from the event tap (`EditKey(event:)`). Anything else is
/// `.other`, which makes keystroke mode give up.
struct EditKey: Equatable {
    enum Action: Equatable {
        /// Printable text, as the keyboard layout typed it.
        case text(String)
        case backspace, forwardDelete
        /// ⌥⌫.
        case deleteWordBack
        case left, right
        /// ⌥← and ⌥→.
        case wordLeft, wordRight
        /// Return or Enter, with or without modifiers: the watch ends.
        case returnKey
        /// Any other key or shortcut.
        case other
    }

    var action: Action
    /// ⇧ held, for ←/→ and ⌥←/⌥→: extends the selection.
    var shift = false

    init(action: Action, shift: Bool = false) {
        self.action = action
        self.shift = shift
    }

    static func text(_ s: String) -> EditKey { EditKey(action: .text(s)) }
    static let backspace = EditKey(action: .backspace), forwardDelete = EditKey(action: .forwardDelete)
    static let deleteWordBack = EditKey(action: .deleteWordBack)
    static let left = EditKey(action: .left), right = EditKey(action: .right)
    static let wordLeft = EditKey(action: .wordLeft), wordRight = EditKey(action: .wordRight)
    static let returnKey = EditKey(action: .returnKey), other = EditKey(action: .other)
    var shifted: EditKey { EditKey(action: action, shift: true) }

    /// Key codes (US layout positions; the same on every layout for these keys).
    enum Code {
        static let returnKey: Int64 = 0x24, enter: Int64 = 0x4C, backspace: Int64 = 0x33, forwardDelete: Int64 = 0x75
        static let left: Int64 = 0x7B, right: Int64 = 0x7C
    }

    /// A key-down from the event tap. ⌘ or ⌃ makes anything but Return a shortcut (`.other`); the
    /// arrows' own fn and keypad flags don't count.
    init(event: CGEvent) {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        self.init(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                  characters: String(utf16CodeUnits: chars, count: min(length, chars.count)))
    }

    init(code: Int64, flags: CGEventFlags, characters: String) {
        let shift = flags.contains(.maskShift), option = flags.contains(.maskAlternate)
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if code == Code.returnKey || code == Code.enter { self.init(action: .returnKey); return }
        guard !shortcut else { self.init(action: .other); return }
        switch code {
        case Code.backspace: self.init(action: option ? .deleteWordBack : .backspace)
        case Code.forwardDelete: self.init(action: option ? .other : .forwardDelete)
        case Code.left: self.init(action: option ? .wordLeft : .left, shift: shift)
        case Code.right: self.init(action: option ? .wordRight : .right, shift: shift)
        default:
            // Tab, Esc, the arrows and function keys type control or private-use characters; a dead
            // key (⌥E) types none until the next key.
            let printable = !characters.isEmpty && characters.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
            self.init(action: printable ? .text(characters) : .other)
        }
    }
}

/// Keystroke mode: the pasted text and what you type into it, followed in memory from your keys,
/// for apps that don't say what's in their text box. The pasted text (the span) is followed as you
/// edit it; text you type after it is kept apart and never part of the edit. Nothing here is saved.
///
/// It gives up (`apply` returns false) wherever it can't be sure what the box now holds: a key it
/// doesn't follow, a move or delete into text it never saw (before the paste or after it), or a
/// word move over Chinese (the app splits Chinese words with a dictionary).
struct TypedEdit {
    /// The pasted text, then anything typed after it.
    private(set) var chars: [Character]
    /// Where the span ends in `chars`.
    private(set) var spanEnd: Int
    private(set) var cursor: Int
    /// The selection's other end, while there's a selection.
    private var anchor: Int?

    init(pasted: String) {
        chars = Array(pasted)
        spanEnd = chars.count
        cursor = chars.count
    }

    /// The pasted text as you've left it.
    var span: String { String(chars[..<spanEnd]) }

    private var selection: Range<Int>? {
        guard let anchor, anchor != cursor else { return nil }
        return min(anchor, cursor)..<max(anchor, cursor)
    }

    /// Applies one key; false: it can't follow this one (give up).
    mutating func apply(_ key: EditKey) -> Bool {
        switch key.action {
        case .text(let text):
            let range = selection ?? cursor..<cursor
            return replace(range, with: Array(text))
        case .backspace:
            if let selection { return replace(selection, with: []) }
            guard cursor > 0 else { return false }
            return replace(cursor - 1..<cursor, with: [])
        case .forwardDelete:
            if let selection { return replace(selection, with: []) }
            guard cursor < chars.count else { return false }
            return replace(cursor..<cursor + 1, with: [])
        case .deleteWordBack:
            if let selection { return replace(selection, with: []) }
            guard let start = wordStart(before: cursor) else { return false }
            return replace(start..<cursor, with: [])
        case .left, .right, .wordLeft, .wordRight:
            return move(key)
        case .returnKey, .other:
            return false
        }
    }

    private mutating func move(_ key: EditKey) -> Bool {
        // ← or → with a selection and no ⇧ lands at its edge, as in every Mac text box.
        if !key.shift, let selection, key.action == .left || key.action == .right {
            cursor = key.action == .left ? selection.lowerBound : selection.upperBound
            anchor = nil
            return true
        }
        let to: Int?
        switch key.action {
        case .left: to = cursor > 0 ? cursor - 1 : nil
        case .right: to = cursor < chars.count ? cursor + 1 : nil
        case .wordLeft: to = wordStart(before: cursor)
        case .wordRight: to = wordEnd(after: cursor)
        default: to = nil
        }
        guard let to else { return false }
        if key.shift { anchor = anchor ?? cursor } else { anchor = nil }
        cursor = to
        return true
    }

    /// Replaces `range` with `text`, keeping the span's end in place: an edit inside the span (or
    /// one going on past its end) is the span's; one after it isn't; text typed right at its end
    /// carries on its last word up to the first space or sentence mark (`SpanTracker.endsRun`).
    private mutating func replace(_ range: Range<Int>, with text: [Character]) -> Bool {
        if range.lowerBound < spanEnd {
            spanEnd = range.upperBound <= spanEnd ? spanEnd - range.count + text.count : range.lowerBound + text.count
        } else if range.lowerBound == spanEnd, range.isEmpty {
            spanEnd += text.prefix { !SpanTracker.endsRun($0) }.count
        }
        chars.replaceSubrange(range, with: text)
        cursor = range.lowerBound + text.count
        anchor = nil
        return true
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" || c == "_" }
    private static func isChinese(_ c: Character) -> Bool { c.unicodeScalars.contains { $0.properties.isIdeographic } }

    /// Where ⌥← from `p` lands: back over spaces and punctuation, then over a word. Nil if that runs
    /// into the start of the pasted text (the word may go on before it) or over Chinese.
    private func wordStart(before p: Int) -> Int? {
        var i = p
        while i > 0, !Self.isWord(chars[i - 1]) { i -= 1 }
        while i > 0, Self.isWord(chars[i - 1]) { i -= 1 }
        guard i > 0, !chars[i..<p].contains(where: Self.isChinese) else { return nil }
        return i
    }

    /// Where ⌥→ from `p` lands; nil if that runs into the end of what's known, or over Chinese.
    private func wordEnd(after p: Int) -> Int? {
        var i = p
        while i < chars.count, !Self.isWord(chars[i]) { i += 1 }
        while i < chars.count, Self.isWord(chars[i]) { i += 1 }
        guard i < chars.count, !chars[p..<i].contains(where: Self.isChinese) else { return nil }
        return i
    }
}
