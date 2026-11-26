import Foundation

/// One key press the user made: what the key types on a US QWERTY layout, and when it went down and
/// up (seconds, any monotonic clock). In memory only.
public struct KeyStroke: Sendable, Equatable {
    public var keyCode: UInt16
    /// The character the key types (QWERTY, Shift applied); nil for keys that type nothing we track.
    public var char: Character?
    public var down: TimeInterval
    public var up: TimeInterval?
    /// A repeat of a held key (the system's auto-repeat).
    public var isRepeat: Bool

    public init(keyCode: UInt16, char: Character?, down: TimeInterval, up: TimeInterval? = nil, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.char = char
        self.down = down
        self.up = up
        self.isRepeat = isRepeat
    }
}

/// Timing evidence for a word as typed: for each pair of letters next to each other, whether the keys
/// went down almost together (a swap of the two is then a likely slip: "teh", "adn"), and whether
/// the second press is the same key hit again too fast to be meant, or held until it repeated
/// ("stilll"). Indices are over the word's characters: `rolled[i]` is about characters i and i + 1.
public struct KeyTiming: Sendable, Equatable {
    public var rolled: [Bool]
    public var doubleHit: [Bool]

    public init(rolled: [Bool], doubleHit: [Bool]) {
        self.rolled = rolled
        self.doubleHit = doubleHit
    }

    /// Evidence from the strokes that typed the word, one per character.
    public init(strokes: [KeyStroke]) {
        var rolled: [Bool] = [], double: [Bool] = []
        for i in strokes.indices.dropLast() {
            let a = strokes[i], b = strokes[i + 1]
            let downGap = b.down - a.down
            rolled.append(a.keyCode != b.keyCode && downGap < KeyTimingLog.rolloverGap)
            double.append(a.keyCode == b.keyCode && (b.isRepeat || downGap < KeyTimingLog.doubleHitGap))
        }
        self.init(rolled: rolled, doubleHit: double)
    }

    public var isEmpty: Bool { !rolled.contains(true) && !doubleHit.contains(true) }
}

/// The user's recent key presses, to back keyboard slips with their timing (`KeyTiming`). Kept in
/// memory only: at most `capacity` presses, cleared after `idleReset` without typing, on Backspace
/// past the start, and by the owner on focus changes, clicks and Secure Input. Pure.
public struct KeyTimingLog: Sendable, Equatable {
    public static let capacity = 48
    public static let idleReset: TimeInterval = 10
    /// Two different keys going down less than this apart (down to down) count as pressed
    /// together. Merely overlapping (the second down before the first is up) does not: fast typists
    /// roll over on most clean letter pairs too.
    public static let rolloverGap: TimeInterval = 0.045
    /// The same key again within this (down to down) is a double hit, not a meant double letter.
    public static let doubleHitGap: TimeInterval = 0.060

    public private(set) var strokes: [KeyStroke] = []

    public init(strokes: [KeyStroke] = []) { self.strokes = strokes }

    /// A `tokenTriggers` key typed at the start of a word ("/", "@", "#"), and what was typed since
    /// (Backspace takes a key back). Kept through arrows, Escape, clicks and focus changes, the ways
    /// a host's picker is used, so a word the picker puts in is still known to belong to the token.
    public private(set) var tokenTrigger: TokenTrigger?

    public struct TokenTrigger: Sendable, Equatable {
        /// When the latest key since the trigger went down.
        public var down: TimeInterval
        /// What was typed after the trigger key.
        public var since: String
    }

    /// Forget the recent presses. `keepingTokenTrigger`: a click, which may be a pick in the
    /// host's token picker.
    public mutating func reset(keepingTokenTrigger: Bool = false) {
        strokes.removeAll()
        if !keepingTokenTrigger { tokenTrigger = nil }
    }

    /// Words finished after the trigger before it lapses: the token's own word, and room for a
    /// space the host adds after it.
    static let tokenTriggerWords = 2

    private mutating func followTokenTrigger(_ char: Character?, backspace: Bool, commandLike: Bool, at time: TimeInterval) {
        if var t = tokenTrigger {
            if time - t.down > Self.idleReset || commandLike {
                tokenTrigger = nil
            } else if backspace {
                if t.since.isEmpty { tokenTrigger = nil } else { t.since.removeLast(); tokenTrigger = t }
            } else if let char {
                t.since.append(char)
                t.down = time
                let words = t.since.split(whereSeparator: { $0.isWhitespace }).count
                tokenTrigger = t.since.last?.isWhitespace == true && words >= Self.tokenTriggerWords ? nil : t
            }
        }
        guard let char, !commandLike, Self.tokenTriggers.contains(char) else { return }
        let prev = strokes.dropLast().last?.char
        if !Self.isWordChar(prev) { tokenTrigger = TokenTrigger(down: time, since: "") }
    }

    /// A key went down. Backspace takes the last press back; keys that type nothing tracked (arrows,
    /// Escape) and shortcuts with Command, Control or Option clear the log (the caret may have moved).
    public mutating func keyDown(keyCode: UInt16, shift: Bool, commandLike: Bool, at time: TimeInterval,
                                 isRepeat: Bool = false) {
        if let last = strokes.last, time - last.down > Self.idleReset { strokes.removeAll() }
        if keyCode == Self.backspaceKey, !commandLike {
            if !strokes.isEmpty { strokes.removeLast() }
            followTokenTrigger(nil, backspace: true, commandLike: false, at: time)
            return
        }
        guard !commandLike, let char = Self.character(keyCode: keyCode, shift: shift) else {
            strokes.removeAll()
            followTokenTrigger(nil, backspace: false, commandLike: commandLike, at: time)
            return
        }
        strokes.append(KeyStroke(keyCode: keyCode, char: char, down: time, isRepeat: isRepeat))
        if strokes.count > Self.capacity { strokes.removeFirst(strokes.count - Self.capacity) }
        followTokenTrigger(char, backspace: false, commandLike: false, at: time)
    }

    /// A press as it is (the eval's simulated or recorded typing).
    public mutating func append(_ stroke: KeyStroke) {
        if let last = strokes.last, stroke.down - last.down > Self.idleReset { strokes.removeAll() }
        strokes.append(stroke)
        if strokes.count > Self.capacity { strokes.removeFirst(strokes.count - Self.capacity) }
        followTokenTrigger(stroke.char, backspace: false, commandLike: false, at: stroke.down)
    }

    /// A key came up: the latest press of that key still down.
    public mutating func keyUp(keyCode: UInt16, at time: TimeInterval) {
        guard let i = strokes.lastIndex(where: { $0.keyCode == keyCode && $0.up == nil }) else { return }
        strokes[i].up = time
    }

    /// Timing for `typed` (a word, or a few words with spaces), from its latest occurrence in the
    /// log that stands on its own (no letter or digit right before or after it). Nil when the keys
    /// don't spell it (paste, input method, another layout, edits) or nothing is unusual.
    public func evidence(for typed: String) -> KeyTiming? {
        let word = Array(Self.fold(typed))
        guard word.count >= 2, strokes.count >= word.count else { return nil }
        let chars = strokes.map { $0.char.map(Self.fold) }
        var end = chars.count
        while end >= word.count {
            let start = end - word.count
            if zip(chars[start..<end], word).allSatisfy({ $0 == $1 }),
               start == 0 || !Self.isWordChar(chars[start - 1]),
               end == chars.count || !Self.isWordChar(chars[end]) {
                let timing = KeyTiming(strokes: Array(strokes[start..<end]))
                return timing.isEmpty ? nil : timing
            }
            end -= 1
        }
        return nil
    }

    /// Characters that start a token many hosts turn into a chip as you type: a slash command
    /// ("/btw"), a mention ("@alex"), a tag ("#general").
    public static let tokenTriggers: Set<Character> = ["/", "@", "#"]

    /// Whether `word` belongs to a token the host may have made a chip of ("/btw", "@alex",
    /// "#general"): typed right after a trigger key, or put in by the host's picker after one (the
    /// keys since the trigger don't spell it). Such a host can show the token without its trigger
    /// character, so the word looks like plain text, but retyping it would destroy the chip.
    public func typedAfterTokenTrigger(_ word: String) -> Bool {
        guard let t = tokenTrigger else { return false }
        let target = Substring(Self.fold(word))
        guard !target.isEmpty else { return false }
        let typed = Self.fold(t.since)
        let words = typed.split(whereSeparator: { !Self.isWordChar($0) && $0 != "'" })
        if typed.hasPrefix(target) { return true }  // "/btw" typed out
        return !words.contains(target)  // put in by the picker: not typed since the trigger
    }

    private static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private static func fold(_ c: Character) -> Character { Character(fold(String(c))) }

    private static func isWordChar(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }

    static let backspaceKey: UInt16 = 51

    /// What a key types on a US ANSI keyboard (macOS virtual key codes). Another layout gives other
    /// characters than the field shows, so its words never match and get no timing.
    public static func character(keyCode: UInt16, shift: Bool) -> Character? {
        guard let pair = keys[keyCode] else { return nil }
        if pair.0.isLetter { return shift ? Character(pair.0.uppercased()) : pair.0 }
        return shift ? pair.1 : pair.0
    }

    private static let keys: [UInt16: (Character, Character)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"), 5: ("g", "G"),
        6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"), 11: ("b", "B"), 12: ("q", "Q"),
        13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"), 16: ("y", "Y"), 17: ("t", "T"),
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"), 23: ("5", "%"),
        24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"), 28: ("8", "*"), 29: ("0", ")"),
        30: ("]", "}"), 31: ("o", "O"), 32: ("u", "U"), 33: ("[", "{"), 34: ("i", "I"), 35: ("p", "P"),
        36: ("\n", "\n"), 37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"),
        42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"), 47: (".", ">"),
        48: ("\t", "\t"), 49: (" ", " "), 50: ("`", "~"), 76: ("\n", "\n"),
    ]

    /// The key code that types `c` on a US ANSI keyboard, and whether Shift is needed (for the eval).
    public static func keyCode(for c: Character) -> (code: UInt16, shift: Bool)? {
        reverse[c]
    }

    private static let reverse: [Character: (code: UInt16, shift: Bool)] = {
        var out: [Character: (code: UInt16, shift: Bool)] = [:]
        for (code, pair) in keys.sorted(by: { $0.key < $1.key }) {
            if out[pair.0] == nil { out[pair.0] = (code, false) }
            if out[pair.1] == nil { out[pair.1] = (code, pair.0 != pair.1) }
        }
        return out
    }()
}

/// A key press as saved with an opt-in typing sample: the character (QWERTY; "\u{8}" Backspace,
/// "" another key), and down/up in ms from the first press. No text beyond what the sample has.
public struct RecordedKey: Codable, Sendable, Equatable {
    public var c: String
    public var d: Int
    public var u: Int?
    /// An auto-repeat of a held key.
    public var r: Bool?

    public static let backspace: Character = "\u{8}"

    public init(c: String, d: Int, u: Int? = nil, r: Bool? = nil) {
        self.c = c
        self.d = d
        self.u = u
        self.r = r
    }

    public static func record(_ strokes: [KeyStroke]) -> [RecordedKey] {
        guard let t0 = strokes.first?.down else { return [] }
        func ms(_ t: TimeInterval) -> Int { Int(((t - t0) * 1000).rounded()) }
        return strokes.map { RecordedKey(c: $0.char.map(String.init) ?? "", d: ms($0.down), u: $0.up.map(ms),
                                         r: $0.isRepeat ? true : nil) }
    }

    /// The presses that typed the end of `typed`, one per character, replayed with Backspace taking
    /// a press back and other keys starting over; nil when they don't spell `typed`'s last
    /// `typed.count` characters (then the sample is replayed without timing).
    public static func strokes(for typed: String, from keys: [RecordedKey]) -> [KeyStroke]? {
        var live: [KeyStroke] = []
        for (i, k) in keys.enumerated() {
            let down = TimeInterval(k.d) / 1000
            if k.c == String(backspace) { if !live.isEmpty { live.removeLast() }; continue }
            guard let c = k.c.first else { live.removeAll(); continue }
            live.append(KeyStroke(keyCode: UInt16(truncatingIfNeeded: i), char: c, down: down,
                                  up: k.u.map { TimeInterval($0) / 1000 }, isRepeat: k.r == true))
        }
        let want = Array(typed.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2019}", with: "'"))
        guard live.count >= want.count else { return nil }
        let tail = Array(live.suffix(want.count))
        guard zip(tail, want).allSatisfy({ $0.char == $1 }) else { return nil }
        // Repeated keys share a key code (rollover and double-hit checks compare codes).
        var codes: [Character: UInt16] = [:]
        return tail.map { s in
            var s = s
            let lower = Character(String(s.char!).lowercased())
            s.keyCode = KeyTimingLog.keyCode(for: lower)?.code ?? codes[lower, default: UInt16(200 + codes.count)]
            codes[lower] = s.keyCode
            return s
        }
    }
}
