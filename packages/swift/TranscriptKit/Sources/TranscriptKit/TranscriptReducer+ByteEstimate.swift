import Foundation

extension TranscriptReducer {
    public static func transcriptByteEstimate(of conversation: [ConversationItem]) -> Int {
        conversation.reduce(0) { total, item in
            switch item {
            case let .user(message):
                return total + message.text.utf8.count
            case let .assistant(message):
                return total
                    + message.turn.entries.reduce(0) { sum, entry in
                        if case let .text(_, markdown) = entry { return sum + markdown.utf8.count }
                        return sum
                    }
            }
        }
    }
}
