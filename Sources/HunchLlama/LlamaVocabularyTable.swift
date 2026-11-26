// In-memory token table built at model load (design §5.2 "Healing"). Never written to disk.
import Foundation
import HunchCore
import llama

/// Raw per-token facts as reported by llama.cpp. Kept separate so the table logic is testable
/// without a model.
struct RawTokenInfo: Sendable {
    var bytes: [UInt8]
    var isControl: Bool
    var isUnused: Bool
    var isByte: Bool
    var isEOG: Bool
    /// USER_DEFINED attribute (matched by the tokenizer even when special parsing is off).
    var isUserDefined: Bool = false

    /// A user-defined token that looks like a chat/control marker (`<|...>`, `<...|>`). Gemma 4
    /// ships several of these (e.g. `<|channel>`, `<|tool_call>`) as USER_DEFINED rather than CONTROL.
    var isMarkerLike: Bool {
        guard isUserDefined, bytes.count > 2, bytes.first == UInt8(ascii: "<"), bytes.last == UInt8(ascii: ">") else {
            return false
        }
        let bar = UInt8(ascii: "|")
        return bytes[1] == bar || bytes[bytes.count - 2] == bar
    }
}

/// Immutable token table: bytes, traits, and a byte-sorted index for `admissible(forRequired:)`.
///
/// Storage is one flat byte array plus offsets; `sortedIDs` orders all non-empty tokens by their
/// bytes so both "tokens starting with `required`" (a contiguous range) and "tokens that are a
/// proper prefix of `required`" (one exact-match lookup per prefix length) are binary searches.
public final class LlamaVocabularyTable: VocabularyTable {
    private let flat: [UInt8]
    private let offsets: [Int32]
    private let traitTable: [TokenTraits]
    private let sortedIDs: [TokenID]
    /// Texts of marker-like user-defined tokens; content tokenization breaks these apart.
    let protectedMarkers: [String]

    public var count: Int { traitTable.count }

    init(_ infos: [RawTokenInfo]) {
        var flat: [UInt8] = []
        flat.reserveCapacity(infos.count * 6)
        var offsets: [Int32] = [0]
        offsets.reserveCapacity(infos.count + 1)
        var traits: [TokenTraits] = []
        traits.reserveCapacity(infos.count)
        for info in infos {
            flat.append(contentsOf: info.bytes)
            offsets.append(Int32(flat.count))
            traits.append(Self.traits(for: info))
        }
        self.flat = flat
        self.offsets = offsets
        self.traitTable = traits
        self.protectedMarkers = infos.filter(\.isMarkerLike).compactMap { String(validating: $0.bytes, as: UTF8.self) }

        var ids = (0..<Int32(infos.count)).filter { offsets[Int($0) + 1] > offsets[Int($0)] }
        flat.withUnsafeBufferPointer { buf in
            ids.sort { a, b in
                let c = Self.compare(buf, offsets, a, b)
                return c != 0 ? c < 0 : a < b
            }
        }
        self.sortedIDs = ids
    }

    /// Builds the table from a loaded vocabulary. Special tokens are rendered with `special = true`
    /// so their text is known, but they are traited `.control`.
    static func build(from vocab: OpaquePointer) -> LlamaVocabularyTable {
        let n = Int(llama_vocab_n_tokens(vocab))
        var infos: [RawTokenInfo] = []
        infos.reserveCapacity(n)
        var buffer = [CChar](repeating: 0, count: 256)
        for i in 0..<n {
            let token = llama_token(i)
            var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
            if length < 0 {
                buffer = [CChar](repeating: 0, count: Int(-length) + 16)
                length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
            }
            let bytes = length > 0 ? buffer[0..<Int(length)].map { UInt8(bitPattern: $0) } : []
            let attr = llama_vocab_get_attr(vocab, token).rawValue
            let control = (attr & (LLAMA_TOKEN_ATTR_CONTROL.rawValue | LLAMA_TOKEN_ATTR_UNKNOWN.rawValue)) != 0
                || llama_vocab_is_control(vocab, token)
            infos.append(RawTokenInfo(
                bytes: bytes,
                isControl: control,
                isUnused: (attr & LLAMA_TOKEN_ATTR_UNUSED.rawValue) != 0,
                isByte: (attr & LLAMA_TOKEN_ATTR_BYTE.rawValue) != 0,
                isEOG: llama_vocab_is_eog(vocab, token),
                isUserDefined: (attr & LLAMA_TOKEN_ATTR_USER_DEFINED.rawValue) != 0
            ))
        }
        return LlamaVocabularyTable(infos)
    }

    public func bytes(_ id: TokenID) -> ArraySlice<UInt8> {
        guard id >= 0, Int(id) < count else { return [] }
        return flat[Int(offsets[Int(id)])..<Int(offsets[Int(id) + 1])]
    }

    public func traits(_ id: TokenID) -> TokenTraits {
        guard id >= 0, Int(id) < count else { return [.control, .unused] }
        return traitTable[Int(id)]
    }

    /// Tokens whose bytes are prefix-compatible with `required`. Tokens with empty bytes are never
    /// returned (they cannot make progress). Masking by traits (control, unused...) is the
    /// decoder's job. An empty `required` returns every non-empty token.
    public func admissible(forRequired required: ArraySlice<UInt8>) -> [TokenID] {
        if required.isEmpty { return sortedIDs.sorted() }
        let req = Array(required)
        var result: [TokenID] = []
        flat.withUnsafeBufferPointer { buf in
            req.withUnsafeBufferPointer { r in
                // 1. Tokens that are proper prefixes of `required`: exact lookups per length.
                for k in 1..<max(1, r.count) {
                    var i = lowerBound(buf, UnsafeBufferPointer(rebasing: r[0..<k]))
                    while i < sortedIDs.count, tokenLength(sortedIDs[i]) == k,
                          Self.hasPrefix(buf, offsets, sortedIDs[i], UnsafeBufferPointer(rebasing: r[0..<k])) {
                        result.append(sortedIDs[i])
                        i += 1
                    }
                }
                // 2. Tokens that start with `required` (including equal): one contiguous range.
                var i = lowerBound(buf, r)
                while i < sortedIDs.count, Self.hasPrefix(buf, offsets, sortedIDs[i], r) {
                    result.append(sortedIDs[i])
                    i += 1
                }
            }
        }
        return result
    }

    // MARK: - Traits

    static func traits(for info: RawTokenInfo) -> TokenTraits {
        var t: TokenTraits = []
        if info.isControl || info.isMarkerLike { t.insert(.control) }
        if info.isUnused { t.insert(.unused) }
        if info.isByte { t.insert(.byteFallback) }
        if info.isEOG { t.insert(.endOfGeneration) }
        if t.contains(.control) || info.isUnused { return t }

        let bytes = info.bytes
        guard !bytes.isEmpty else { return t }
        guard let text = String(validating: bytes, as: UTF8.self) else {
            t.insert(.invalidUTF8Alone)
            return t
        }
        let scalars = Array(text.unicodeScalars)
        let first = scalars[0]
        if first == " " || first == "\u{2581}" { t.insert(.leadingSpace) }
        if scalars.contains(where: { $0 == "\n" || $0 == "\r" }) { t.insert(.containsNewline) }
        if scalars.contains(where: { $0 == "," || $0 == "\u{FF0C}" || $0 == "\u{3001}" }) { t.insert(.containsComma) }

        let body = scalars.drop(while: { isSpace($0) })
        if body.count < scalars.count, let lead = body.first, !closingPunctuation.contains(lead) {
            // Whitespace followed by something that opens a word (letter, digit, opening mark...).
            t.insert(.wordStart)
        }
        let trimmed = body.reversed().drop(while: { isSpace($0) })
        if !trimmed.isEmpty, trimmed.allSatisfy({ isPunctuationOrSymbol($0) }) { t.insert(.punctuation) }
        if let last = trimmed.first, sentenceEnders.contains(last) { t.insert(.sentenceEnd) }
        return t
    }

    private static let sentenceEnders: Set<Unicode.Scalar> = [".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
    private static let closingPunctuation: Set<Unicode.Scalar> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "\u{2026}", "\u{3002}", "\u{FF0C}", "\u{3001}",
    ]

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == "\u{2581}" || s.properties.isWhitespace
    }

    private static func isPunctuationOrSymbol(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    // MARK: - Byte comparisons

    private func tokenLength(_ id: TokenID) -> Int {
        Int(offsets[Int(id) + 1] - offsets[Int(id)])
    }

    /// First index in `sortedIDs` whose bytes are >= `key`.
    private func lowerBound(_ buf: UnsafeBufferPointer<UInt8>, _ key: UnsafeBufferPointer<UInt8>) -> Int {
        var lo = 0
        var hi = sortedIDs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Self.compare(buf, offsets, sortedIDs[mid], key) < 0 { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func compare(_ buf: UnsafeBufferPointer<UInt8>, _ offsets: [Int32], _ a: TokenID, _ b: TokenID) -> Int {
        let sb = Int(offsets[Int(b)])
        let key = UnsafeBufferPointer(rebasing: buf[sb..<Int(offsets[Int(b) + 1])])
        return compare(buf, offsets, a, key)
    }

    private static func compare(_ buf: UnsafeBufferPointer<UInt8>, _ offsets: [Int32], _ a: TokenID,
                                _ key: UnsafeBufferPointer<UInt8>) -> Int {
        let sa = Int(offsets[Int(a)])
        let la = Int(offsets[Int(a) + 1]) - sa
        let n = min(la, key.count)
        if n > 0, let base = buf.baseAddress, let kb = key.baseAddress {
            let c = memcmp(base + sa, kb, n)
            if c != 0 { return Int(c) }
        }
        return la - key.count
    }

    private static func hasPrefix(_ buf: UnsafeBufferPointer<UInt8>, _ offsets: [Int32], _ id: TokenID,
                                  _ prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        let s = Int(offsets[Int(id)])
        let l = Int(offsets[Int(id) + 1]) - s
        guard l >= prefix.count else { return false }
        guard prefix.count > 0, let base = buf.baseAddress, let pb = prefix.baseAddress else { return true }
        return memcmp(base + s, pb, prefix.count) == 0
    }
}
