import Foundation
import Testing
@testable import HunchEndpoint
import HunchCore

@Suite struct SSEParserTests {
    private func parse(_ chunks: [String]) -> [SSEEvent] {
        var p = SSEParser()
        return chunks.flatMap { p.feed(Data($0.utf8)) }
    }

    @Test func singleEvent() {
        #expect(parse(["data: hello\n\n"]) == [SSEEvent(data: "hello")])
    }

    @Test func splitAtEveryByte() {
        let text = "event: x\ndata: a\ndata: b\n\ndata: [DONE]\n\n"
        var p = SSEParser()
        var out: [SSEEvent] = []
        for b in Data(text.utf8) { out += p.feed(Data([b])) }
        #expect(out == [SSEEvent(event: "x", data: "a\nb"), SSEEvent(data: "[DONE]")])
        #expect(out[1].isDone)
    }

    @Test func crlfAndCr() {
        #expect(parse(["data: a\r\n\r\ndata: b\r\r"]) == [SSEEvent(data: "a"), SSEEvent(data: "b")])
    }

    @Test func crlfSplitAcrossChunks() {
        #expect(parse(["data: a\r", "\n\r", "\n"]) == [SSEEvent(data: "a")])
    }

    @Test func commentsIgnored() {
        #expect(parse([": keep-alive\n\ndata: x\n: note\n\n"]) == [SSEEvent(data: "x")])
    }

    @Test func noSpaceAfterColonAndEmptyData() {
        #expect(parse(["data:x\n\n", "data\n\n"]) == [SSEEvent(data: "x"), SSEEvent(data: "")])
    }

    @Test func unknownFieldsIgnoredAndUnterminatedDropped() {
        #expect(parse(["id: 4\nretry: 10\ndata: k\n\ndata: partial"]) == [SSEEvent(data: "k")])
    }

    @Test func multibyteSplitAcrossChunks() {
        let bytes = Array("data: héllo\n\n".utf8)
        var p = SSEParser()
        var out = p.feed(Data(bytes[..<8]))
        out += p.feed(Data(bytes[8...]))
        #expect(out == [SSEEvent(data: "héllo")])
    }

    @Test func eventNameResetsBetweenEvents() {
        #expect(parse(["event: a\ndata: 1\n\ndata: 2\n\n"]) == [SSEEvent(event: "a", data: "1"), SSEEvent(data: "2")])
    }

    @Test func blankLinesWithoutDataEmitNothing() {
        #expect(parse(["\n\n\n"]).isEmpty)
    }
}
