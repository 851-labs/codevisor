import Foundation
import Testing
@testable import ACPAgents
import ACPKit

@Suite("Process integration", .serialized)
struct ProcessIntegrationTests {
    @Test("ProcessCommandRunner captures stdout and exit code")
    func runnerStdout() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello world"],
            environment: nil
        )
        #expect(result.standardOutput.contains("hello world"))
        #expect(result.exitCode == 0)
    }

    @Test("ProcessCommandRunner captures stderr and non-zero exit")
    func runnerStderr() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo oops 1>&2; exit 3"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(result.standardError.contains("oops"))
        #expect(result.exitCode == 3)
    }

    @Test("StdioTransportProvider starts a real transport")
    func transportProvider() async throws {
        let provider = StdioTransportProvider()
        let transport = try provider.makeTransport(
            for: ProcessSpec(executableURL: URL(fileURLWithPath: "/bin/cat"))
        )
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        try await transport.send(message)
        var received: Data?
        for try await line in transport.incoming {
            received = line
            break
        }
        transport.close()
        #expect(received != nil)
    }

    @Test("StdioTransportProvider propagates launch failure")
    func transportProviderFailure() {
        let provider = StdioTransportProvider()
        #expect(throws: (any Error).self) {
            _ = try provider.makeTransport(
                for: ProcessSpec(executableURL: URL(fileURLWithPath: "/no/such/bin"))
            )
        }
    }
}
