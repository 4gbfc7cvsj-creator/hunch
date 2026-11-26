import Foundation
import Testing
import HunchCore
@testable import HunchModels

// MARK: Tiny GGUF writer

private struct GGUFBuilder {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func str(_ s: String) { u64(UInt64(s.utf8.count)); data.append(contentsOf: Array(s.utf8)) }
    mutating func header(version: UInt32 = 3, tensors: UInt64 = 7, kvs: UInt64) {
        data.append(contentsOf: Array("GGUF".utf8)); u32(version); u64(tensors); u64(kvs)
    }
    mutating func kvString(_ k: String, _ v: String) { str(k); u32(8); str(v) }
    mutating func kvU32(_ k: String, _ v: UInt32) { str(k); u32(4); u32(v) }
    mutating func kvU64(_ k: String, _ v: UInt64) { str(k); u32(10); u64(v) }
    mutating func kvU16(_ k: String, _ v: UInt16) { str(k); u32(2); u16(v) }
    mutating func kvBool(_ k: String, _ v: Bool) { str(k); u32(7); u8(v ? 1 : 0) }
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("gtgguf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func write(_ data: Data, named name: String, in dir: URL) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try data.write(to: u)
    return u
}

/// A file exercising every value type, nested arrays and the keys we keep.
private func fullFile(version: UInt32) -> Data {
    var b = GGUFBuilder()
    b.header(version: version, tensors: 42, kvs: 18)
    b.kvString("general.architecture", "gemma4")
    // Arrays of strings, nested arrays, and every scalar type before the interesting keys.
    b.str("tokenizer.ggml.tokens"); b.u32(9); b.u32(8); b.u64(3); b.str("a"); b.str("bb"); b.str("")
    b.str("nested"); b.u32(9); b.u32(9); b.u64(2)
    b.u32(4); b.u64(2); b.u32(1); b.u32(2)
    b.u32(8); b.u64(1); b.str("x")
    b.str("t.u8"); b.u32(0); b.u8(1)
    b.str("t.i8"); b.u32(1); b.u8(0xFF)
    b.str("t.u16"); b.u32(2); b.u16(5)
    b.str("t.i16"); b.u32(3); b.u16(0xFFFF)
    b.str("t.i32"); b.u32(5); b.u32(0xFFFF_FFFF)
    b.str("t.f32"); b.u32(6); b.u32(0x3F80_0000)
    b.str("t.i64"); b.u32(11); b.u64(1)
    b.str("t.f64"); b.u32(12); b.u64(0x3FF0_0000_0000_0000)
    b.kvString("general.name", "Test Model")
    b.kvString("general.type", "model")
    b.kvU16("gemma4.context_length", 8192)        // narrow width, coerced
    b.kvU64("gemma4.attention.sliding_window", 512)    // wide width, coerced
    b.kvU32("general.file_type", 17)
    b.kvBool("tokenizer.ggml.add_bos_token", true)
    b.kvString("tokenizer.chat_template", "{{ messages }}")
    return b.data
}

@Suite struct GGUFInspectorTests {
    let inspector = GGUFInspector()

    @Test(arguments: [UInt32(2), UInt32(3)])
    func validSummary(version: UInt32) throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // kv count in header (18) is exact for the number of entries written by fullFile.
        let url = try write(fullFile(version: version), named: "m.gguf", in: dir)
        let (v, s) = inspector.inspect(url)
        #expect(v == .valid)
        #expect(s?.version == version)
        #expect(s?.architecture == "gemma4")
        #expect(s?.name == "Test Model")
        #expect(s?.type == "model")
        #expect(s?.contextLength == 8192)
        #expect(s?.slidingWindow == 512)
        #expect(s?.fileType == 17)
        #expect(s?.addBOS == true)
        #expect(s?.chatTemplate == "{{ messages }}")
        #expect(s?.tensorCount == 42)
    }

    @Test func contextKeyBeforeArchitecture() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 2)
        b.kvU32("llama.context_length", 4096)
        b.kvString("general.architecture", "llama")
        let (v, s) = inspector.inspect(try write(b.data, named: "m.gguf", in: dir))
        #expect(v == .valid)
        #expect(s?.contextLength == 4096)
    }

    @Test func longChatTemplateIsCapped() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 2)
        b.kvString("tokenizer.chat_template", String(repeating: "x", count: 200_000))
        b.kvString("general.name", "after")
        let (v, s) = inspector.inspect(try write(b.data, named: "m.gguf", in: dir))
        #expect(v == .valid)
        #expect(s?.chatTemplate?.utf8.count == 64 * 1024)
        #expect(s?.name == "after")
    }

    @Test func notGGUF() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SystemRandomNumberGenerator()
        var bytes = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &rng) }
        bytes[0] = 0x00
        let (v, s) = inspector.inspect(try write(Data(bytes), named: "enc.gguf", in: dir))
        #expect(v == .notGGUF)
        #expect(s == nil)
        let (v2, _) = inspector.inspect(try write(Data(), named: "empty.gguf", in: dir))
        #expect(v2 == .notGGUF)
    }

    @Test func truncated() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let full = fullFile(version: 3)
        for cut in [2, 10, 20, full.count / 2, full.count - 3] {
            let (v, _) = inspector.inspect(try write(full.prefix(cut), named: "t\(cut).gguf", in: dir))
            #expect(v == .truncated, "cut at \(cut)")
        }
    }

    @Test func badVersion() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(version: 9, kvs: 0)
        let (v, _) = inspector.inspect(try write(b.data, named: "v.gguf", in: dir))
        #expect(v == .unsupportedVersion(9))
    }

    @Test func hugeStringIsMalformed() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 1)
        b.str("general.name"); b.u32(8); b.u64(1 << 40)
        let (v, _) = inspector.inspect(try write(b.data, named: "h.gguf", in: dir))
        guard case .malformedMetadata = v else { Issue.record("got \(v)"); return }
    }

    @Test func absurdCountsAndTypes() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 5_000_000)
        guard case .malformedMetadata = inspector.inspect(try write(b.data, named: "k.gguf", in: dir)).0 else {
            Issue.record("kv count"); return
        }
        var c = GGUFBuilder(); c.header(kvs: 1); c.str("x"); c.u32(99)
        guard case .malformedMetadata = inspector.inspect(try write(c.data, named: "t.gguf", in: dir)).0 else {
            Issue.record("type id"); return
        }
        var d = GGUFBuilder(); d.header(kvs: 1); d.str("x"); d.u32(9); d.u32(4); d.u64(1 << 40)
        guard case .malformedMetadata = inspector.inspect(try write(d.data, named: "a.gguf", in: dir)).0 else {
            Issue.record("array length"); return
        }
    }

    @Test func splitPartName() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 1); b.kvString("general.architecture", "llama")
        let (v, s) = inspector.inspect(try write(b.data, named: "Model-Q4-00001-of-00003.gguf", in: dir))
        #expect(v == .splitPart(index: 1, of: 3))
        #expect(s?.architecture == "llama")
        #expect(GGUFInspector.splitInfo("plain-model.gguf") == nil)
    }

    @Test func mmprojAuxiliary() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var b = GGUFBuilder(); b.header(kvs: 2)
        b.kvString("general.architecture", "clip"); b.kvString("general.type", "mmproj")
        guard case .auxiliary = inspector.inspect(try write(b.data, named: "x.gguf", in: dir)).0 else {
            Issue.record("type"); return
        }
        var c = GGUFBuilder(); c.header(kvs: 1); c.kvString("general.architecture", "llama")
        guard case .auxiliary = inspector.inspect(try write(c.data, named: "mmproj-foo.gguf", in: dir)).0 else {
            Issue.record("filename"); return
        }
        var d = GGUFBuilder(); d.header(kvs: 1); d.kvString("general.architecture", "clip")
        guard case .auxiliary = inspector.inspect(try write(d.data, named: "y.gguf", in: dir)).0 else {
            Issue.record("arch"); return
        }
    }

    @Test func unreadable() throws {
        let dir = try tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = try write(fullFile(version: 3), named: "locked.gguf", in: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        if getuid() == 0 { return }
        guard case .unreadable = inspector.inspect(url).0 else { Issue.record("expected unreadable"); return }
        guard case .unreadable = inspector.inspect(dir.appendingPathComponent("missing.gguf")).0 else {
            Issue.record("missing"); return
        }
    }

    @Test func realFolderIfPresent() throws {
        let folder = URL(fileURLWithPath: "/Volumes/Samsung 1TB/LLM/GhostType")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let ggufs = files.sorted().filter { $0.lowercased().hasSuffix(".gguf") && !$0.hasPrefix(".") }
        // Wake the drive before the clock starts: a sleeping external drive takes a while to spin up,
        // and that is not what the time limit below is meant to measure.
        for f in ggufs {
            if let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent(f)) {
                _ = try? h.read(upToCount: 1)
                try? h.close()
            }
        }
        let start = Date()
        for f in ggufs {
            let (v, s) = inspector.inspect(folder.appendingPathComponent(f))
            print("GGUF-REAL \(f): \(v) arch=\(s?.architecture ?? "-") name=\(s?.name ?? "-")")
            if f == "gemma-4-E4B-Q5_C.gguf" {
                #expect(v == .notGGUF)
            } else {
                #expect(v == .valid)
                // Any model can be added here, so only check that the architecture was read.
                #expect(s?.architecture?.isEmpty == false, "\(f): no architecture")
            }
        }
        #expect(Date().timeIntervalSince(start) < 2 * Double(max(ggufs.count, 1)))  // headers only; budget per file, drive already woken above
    }
}
