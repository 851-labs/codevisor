import Testing
@testable import CodevisorCore

@Suite("Command line codec")
struct CommandLineCodecTests {
    @Test func parsesQuotedArgumentsAndEscapes() throws {
        #expect(try CommandLineCodec.parse("npx -y 'package name' \"two words\" escaped\\ value") == [
            "npx", "-y", "package name", "two words", "escaped value"
        ])
    }

    @Test func preservesEmptyArguments() throws {
        #expect(try CommandLineCodec.parse("command '' \"\"") == ["command", "", ""])
    }

    @Test func formattingRoundTripsComponents() throws {
        let components = ["/path with spaces/tool", "simple", "it's quoted", "", "$literal"]
        #expect(try CommandLineCodec.parse(CommandLineCodec.format(components)) == components)
    }

    @Test func rejectsIncompleteInput() {
        #expect(throws: CommandLineCodec.ParseError.unterminatedSingleQuote) {
            try CommandLineCodec.parse("command 'unfinished")
        }
        #expect(throws: CommandLineCodec.ParseError.trailingEscape) {
            try CommandLineCodec.parse("command \\")
        }
    }
}
