import Foundation
import Testing
@testable import ACPKit

@Suite("NDJSONFramer")
struct NDJSONFramerTests {
    @Test("Splits complete lines and buffers partial ones")
    func splitsAndBuffers() {
        var framer = NDJSONFramer()
        var messages = framer.append(Data("hello\nwor".utf8))
        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == ["hello"])
        messages = framer.append(Data("ld\n".utf8))
        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == ["world"])
    }

    @Test("Handles multiple messages in one chunk")
    func multiple() {
        var framer = NDJSONFramer()
        let messages = framer.append(Data("a\nb\nc\n".utf8))
        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == ["a", "b", "c"])
    }

    @Test("Skips empty lines")
    func skipsEmpty() {
        var framer = NDJSONFramer()
        let messages = framer.append(Data("\n\nx\n\n".utf8))
        #expect(messages.map { String(decoding: $0, as: UTF8.self) } == ["x"])
    }

    @Test("Returns nothing when no newline yet")
    func noNewline() {
        var framer = NDJSONFramer()
        let messages = framer.append(Data("partial".utf8))
        #expect(messages.isEmpty)
    }

    @Test("Frames a message by appending a newline")
    func frame() {
        let framed = NDJSONFramer.frame(Data("{}".utf8))
        #expect(String(decoding: framed, as: UTF8.self) == "{}\n")
    }

    @Test("Splits byte-by-byte input correctly")
    func byteByByte() {
        var framer = NDJSONFramer()
        var collected: [String] = []
        for byte in Data("ab\ncd\n".utf8) {
            for message in framer.append(Data([byte])) {
                collected.append(String(decoding: message, as: UTF8.self))
            }
        }
        #expect(collected == ["ab", "cd"])
    }
}
