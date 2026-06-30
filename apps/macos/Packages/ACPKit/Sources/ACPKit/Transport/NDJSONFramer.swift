import Foundation

/// Accumulates incoming bytes and splits them into newline-delimited JSON
/// messages, per the ACP stdio transport ("Messages are delimited by newlines
/// (`\n`), and MUST NOT contain embedded newlines").
///
/// This logic is isolated from `Process` so it can be unit tested directly with
/// arbitrary chunk boundaries.
public struct NDJSONFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// The newline byte used to delimit messages.
    private static let newline = UInt8(ascii: "\n")

    /// Appends a chunk of bytes and returns any complete messages that became
    /// available. Each returned `Data` is a single message with the trailing
    /// newline removed. Empty lines are skipped.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var messages: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: Self.newline) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            if !line.isEmpty {
                messages.append(Data(line))
            }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return messages
    }

    /// Frames an outbound message by appending a single newline. The message
    /// must not already contain a newline.
    public static func frame(_ message: Data) -> Data {
        var framed = message
        framed.append(newline)
        return framed
    }
}
