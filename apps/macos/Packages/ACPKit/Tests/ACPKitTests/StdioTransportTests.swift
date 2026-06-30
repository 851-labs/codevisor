import Foundation
import Testing
@testable import ACPKit

@Suite("StdioTransport", .serialized)
struct StdioTransportTests {
    @Test("Echoes a framed message through a real subprocess")
    func echo() async throws {
        // `cat` echoes stdin to stdout, exercising send + framed read.
        let transport = StdioTransport(spec: ProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/cat")
        ))
        try transport.start()

        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        try await transport.send(message)

        var received: Data?
        for try await line in transport.incoming {
            received = line
            break
        }
        transport.close()

        #expect(received != nil)
        let inbound = try JSONRPCInbound(data: received!)
        guard case .request(let request) = inbound else { Issue.record("expected request"); return }
        #expect(request.method == "ping")
    }

    @Test("Surfaces stderr output")
    func stderr() async throws {
        let transport = StdioTransport(spec: ProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo diagnostic 1>&2; sleep 0.2"]
        ))
        try transport.start()

        var logged = ""
        for await chunk in transport.stderr {
            logged += chunk
            if logged.contains("diagnostic") { break }
        }
        transport.close()
        #expect(logged.contains("diagnostic"))
    }

    @Test("Finishes incoming when the process exits")
    func processExit() async throws {
        let transport = StdioTransport(spec: ProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 0"]
        ))
        try transport.start()

        // The stream should terminate without producing messages.
        var count = 0
        for try await _ in transport.incoming { count += 1 }
        #expect(count == 0)
        transport.close()
    }

    @Test("Throws when the executable does not exist")
    func badExecutable() {
        let transport = StdioTransport(spec: ProcessSpec(
            executableURL: URL(fileURLWithPath: "/nonexistent/binary-xyz")
        ))
        #expect(throws: (any Error).self) {
            try transport.start()
        }
    }

    @Test("ProcessSpec stores its configuration")
    func processSpec() {
        let spec = ProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node"],
            environment: ["PATH": "/usr/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        #expect(spec.arguments == ["node"])
        #expect(spec.environment["PATH"] == "/usr/bin")
        #expect(spec.currentDirectoryURL?.path == "/tmp")
        #expect(spec == ProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node"],
            environment: ["PATH": "/usr/bin"],
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        ))
    }
}
