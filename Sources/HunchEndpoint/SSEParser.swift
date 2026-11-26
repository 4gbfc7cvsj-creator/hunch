// Incremental Server-Sent Events parser. Pure; no I/O.
import Foundation
import HunchCore

/// Parses an SSE byte stream delivered in arbitrary chunks.
///
/// Handles LF, CRLF, and CR line endings (including a CRLF split across chunks), comment lines
/// (starting with ":"), multi-line `data:` fields (joined with "\n"), `event:` names, and a UTF-8
/// character split across chunks (lines are decoded only once complete). Unknown fields (`id`,
/// `retry`) are ignored. An event is dispatched at a blank line and only if it has data; the
/// terminal `data: [DONE]` of OpenAI-style streams is delivered as an ordinary event (see
/// `SSEEvent.isDone`). A trailing unterminated event is dropped, as the SSE spec requires.
public struct SSEParser: SSEParsing {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var skipLF = false

    public init() {}

    public mutating func feed(_ bytes: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if skipLF {
                skipLF = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                skipLF = true
                finishLine(into: &events)
            case 0x0A:
                finishLine(into: &events)
            default:
                line.append(byte)
            }
        }
        return events
    }

    private mutating func finishLine(into events: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            if !dataLines.isEmpty {
                events.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n")))
            }
            dataLines.removeAll()
            eventName = nil
            return
        }
        if line[0] == 0x3A { return }  // comment
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        default: break
        }
    }
}

extension SSEEvent {
    /// True for the OpenAI-style end-of-stream sentinel.
    public var isDone: Bool { data.trimmingCharacters(in: .whitespaces) == "[DONE]" }
}
