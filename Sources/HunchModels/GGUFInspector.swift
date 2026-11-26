import Foundation
import HunchCore

/// Reads only the GGUF header and metadata KV section (never tensor data).
public struct GGUFInspector: GGUFInspecting {
    static let maxStringBytes = 1 << 20
    static let maxChatTemplateBytes = 64 * 1024
    static let maxArrayLength: UInt64 = 16_000_000
    static let maxKVCount: UInt64 = 100_000
    static let maxMetadataBytes: UInt64 = 64 << 20
    static let maxArrayDepth = 8

    public init() {}

    public func inspect(_ url: URL) -> (GGUFValidity, GGUFSummary?) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return (.unreadable(error.localizedDescription), nil)
        }
        defer { try? handle.close() }

        let fileSize: UInt64
        do {
            fileSize = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            return (.unreadable(error.localizedDescription), nil)
        }

        let reader = Reader(handle: handle, fileSize: fileSize)
        let fileName = url.lastPathComponent
        do {
            let summary = try Self.parse(reader)
            return (Self.classify(summary: summary, fileName: fileName), summary)
        } catch let e as Failure {
            switch e {
            case .notGGUF: return (.notGGUF, nil)
            case .truncated: return (.truncated, nil)
            case .version(let v): return (.unsupportedVersion(v), nil)
            case .malformed(let r): return (.malformedMetadata(r), nil)
            case .io(let m): return (.unreadable(m), nil)
            }
        } catch {
            return (.unreadable(error.localizedDescription), nil)
        }
    }

    // MARK: Classification

    static func classify(summary: GGUFSummary, fileName: String) -> GGUFValidity {
        let lower = fileName.lowercased()
        let arch = summary.architecture?.lowercased() ?? ""
        if summary.type?.lowercased() == "mmproj" || lower.hasPrefix("mmproj") {
            return .auxiliary("vision projector")
        }
        if arch == "clip" || arch.contains("projector") {
            return .auxiliary("vision projector")
        }
        if let (i, n) = splitInfo(lower) { return .splitPart(index: i, of: n) }
        return .valid
    }

    static func splitInfo(_ lowerName: String) -> (Int, Int)? {
        guard lowerName.hasSuffix(".gguf") else { return nil }
        let stem = String(lowerName.dropLast(5))
        let parts = stem.components(separatedBy: "-of-")
        guard parts.count == 2, let second = parts.last, let first = parts.first else { return nil }
        let nDigits = second.prefix(while: { $0.isASCII && $0.isNumber })
        guard nDigits.count == second.count, !nDigits.isEmpty else { return nil }
        let idxDigits = first.reversed().prefix(while: { $0.isASCII && $0.isNumber })
        guard !idxDigits.isEmpty, first.dropLast(idxDigits.count).hasSuffix("-"),
              let n = Int(nDigits), let i = Int(String(idxDigits.reversed())) else { return nil }
        return (i, n)
    }

    // MARK: Parsing

    enum Failure: Error {
        case notGGUF, truncated, version(UInt32), malformed(String), io(String)
    }

    enum Value {
        case int(Int64)
        case uint(UInt64)
        case bool(Bool)
        case string(String)

        var intValue: Int? {
            switch self {
            case .int(let v): return v >= 0 ? Int(exactly: v) : nil
            case .uint(let v): return Int(exactly: v)
            default: return nil
            }
        }
        var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
        var boolValue: Bool? {
            switch self {
            case .bool(let b): return b
            case .int(let v): return v != 0
            case .uint(let v): return v != 0
            default: return nil
            }
        }
    }

    static func parse(_ r: Reader) throws -> GGUFSummary {
        let magic = try r.readBytesAllowingShort(4)
        let expected: [UInt8] = [0x47, 0x47, 0x55, 0x46]
        if magic != expected {
            if magic.count < 4 && magic == Array(expected.prefix(magic.count)) && !magic.isEmpty { throw Failure.truncated }
            throw Failure.notGGUF
        }
        let version: UInt32 = try r.readU32()
        guard version == 2 || version == 3 else { throw Failure.version(version) }
        let tensorCount = try r.readU64()
        let kvCount = try r.readU64()
        guard kvCount < maxKVCount else { throw Failure.malformed("implausible metadata count \(kvCount)") }

        var summary = GGUFSummary(version: version, tensorCount: tensorCount)
        var ints: [String: Int] = [:]
        var arch: String?

        for _ in 0..<kvCount {
            if r.position > maxMetadataBytes { throw Failure.malformed("metadata section too large") }
            let key = try r.readString(limit: 4096, keep: 4096) ?? ""
            let typeID = try r.readU32()
            let keep = wanted(key)
            let value = try readValue(r, typeID: typeID, keep: keep, cap: key == "tokenizer.chat_template" ? maxChatTemplateBytes : maxStringBytes, depth: 0)
            guard let value else { continue }
            switch key {
            case "general.architecture": arch = value.stringValue; summary.architecture = arch
            case "general.name": summary.name = value.stringValue
            case "general.type": summary.type = value.stringValue
            case "general.basename": summary.baseName = value.stringValue
            case "general.finetune": summary.finetune = value.stringValue
            case "general.size_label": summary.sizeLabel = value.stringValue
            case "general.file_type": summary.fileType = value.intValue.flatMap { UInt32(exactly: $0) }
            case "tokenizer.chat_template": summary.chatTemplate = value.stringValue
            case "tokenizer.ggml.add_bos_token": summary.addBOS = value.boolValue
            default:
                if let i = value.intValue { ints[key] = i }
            }
        }
        if let arch {
            summary.contextLength = ints["\(arch).context_length"]
            summary.slidingWindow = ints["\(arch).attention.sliding_window"]
        }
        return summary
    }

    static func wanted(_ key: String) -> Bool {
        switch key {
        case "general.architecture", "general.name", "general.type", "general.basename", "general.finetune",
             "general.size_label", "general.file_type", "tokenizer.chat_template", "tokenizer.ggml.add_bos_token":
            return true
        default:
            return key.hasSuffix(".context_length") || key.hasSuffix(".attention.sliding_window")
        }
    }

    static func fixedSize(_ t: UInt32) -> UInt64? {
        switch t {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil
        }
    }

    /// Reads (or skips) a value. Returns nil when skipped or when the kept type is not scalar/string.
    static func readValue(_ r: Reader, typeID: UInt32, keep: Bool, cap: Int, depth: Int) throws -> Value? {
        switch typeID {
        case 8:
            if keep { return try r.readString(limit: maxStringBytes, keep: cap).map { .string($0) } }
            _ = try r.readString(limit: maxStringBytes, keep: 0)
            return nil
        case 9:
            guard depth < maxArrayDepth else { throw Failure.malformed("arrays nested too deeply") }
            let elemType = try r.readU32()
            let count = try r.readU64()
            guard count <= maxArrayLength else { throw Failure.malformed("implausible array length \(count)") }
            if let size = fixedSize(elemType) {
                try r.skip(count * size)
            } else if elemType == 8 {
                for _ in 0..<count { _ = try r.readString(limit: maxStringBytes, keep: 0) }
            } else if elemType == 9 {
                for _ in 0..<count { _ = try readValue(r, typeID: 9, keep: false, cap: 0, depth: depth + 1) }
            } else {
                throw Failure.malformed("unknown value type \(elemType)")
            }
            return nil
        default:
            guard let size = fixedSize(typeID) else { throw Failure.malformed("unknown value type \(typeID)") }
            if !keep { try r.skip(size); return nil }
            switch typeID {
            case 0: return .uint(UInt64(try r.readUInt(1)))
            case 1: return .int(Int64(Int8(truncatingIfNeeded: try r.readUInt(1))))
            case 2: return .uint(try r.readUInt(2))
            case 3: return .int(Int64(Int16(truncatingIfNeeded: try r.readUInt(2))))
            case 4: return .uint(try r.readUInt(4))
            case 5: return .int(Int64(Int32(truncatingIfNeeded: try r.readUInt(4))))
            case 7: return .bool(try r.readUInt(1) != 0)
            case 10: return .uint(try r.readUInt(8))
            case 11: return .int(Int64(bitPattern: try r.readUInt(8)))
            default: try r.skip(size); return nil // floats
            }
        }
    }

    // MARK: Buffered reader

    final class Reader {
        private let handle: FileHandle
        private let fileSize: UInt64
        private var buffer = Data()
        private var bufferStart: UInt64 = 0  // file offset of buffer[buffer.startIndex]
        private(set) var position: UInt64 = 0
        private static let chunk = 64 * 1024

        init(handle: FileHandle, fileSize: UInt64) {
            self.handle = handle
            self.fileSize = fileSize
        }

        private func fill(_ n: Int) throws {
            // Ensure bytes [position, position+n) are in buffer.
            let end = position + UInt64(n)
            guard end <= fileSize else { throw Failure.truncated }
            let bufEnd = bufferStart + UInt64(buffer.count)
            if position >= bufferStart && end <= bufEnd { return }
            do {
                try handle.seek(toOffset: position)
                let want = max(n, Reader.chunk)
                buffer = try handle.read(upToCount: want) ?? Data()
                buffer = Data(buffer) // rebase indices
                bufferStart = position
            } catch {
                throw Failure.io(error.localizedDescription)
            }
            if buffer.count < n { throw Failure.truncated }
        }

        func readBytes(_ n: Int) throws -> [UInt8] {
            try fill(n)
            let off = Int(position - bufferStart)
            let out = Array(buffer[off..<(off + n)])
            position += UInt64(n)
            return out
        }

        func readBytesAllowingShort(_ n: Int) throws -> [UInt8] {
            let avail = Int(min(UInt64(n), fileSize - min(position, fileSize)))
            return avail == 0 ? [] : try readBytes(avail)
        }

        func readUInt(_ size: Int) throws -> UInt64 {
            let b = try readBytes(size)
            var v: UInt64 = 0
            for (i, byte) in b.enumerated() { v |= UInt64(byte) << UInt64(8 * i) }
            return v
        }
        func readU32() throws -> UInt32 { UInt32(truncatingIfNeeded: try readUInt(4)) }
        func readU64() throws -> UInt64 { try readUInt(8) }

        func skip(_ n: UInt64) throws {
            let (end, overflow) = position.addingReportingOverflow(n)
            guard !overflow, end <= fileSize else { throw Failure.truncated }
            position = end
        }

        /// Reads a length-prefixed string. Throws malformed if the length exceeds `limit`.
        /// Keeps at most `keep` bytes (rest skipped); returns nil if `keep == 0`.
        func readString(limit: Int, keep: Int) throws -> String? {
            let len = try readU64()
            guard len <= UInt64(limit) else { throw Failure.malformed("string length \(len) exceeds limit") }
            if keep == 0 { try skip(len); return nil }
            let take = Int(min(len, UInt64(keep)))
            let bytes = try readBytes(take)
            try skip(len - UInt64(take))
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
