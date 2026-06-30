import Foundation
@testable import ACPAgents
import ACPKit

enum FakeError: Error { case boom }

/// A command runner returning a preconfigured result.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let result: Result<CommandResult, FakeError>
    private let lock = NSLock()
    private(set) var invocations: [(URL, [String])] = []

    init(_ result: Result<CommandResult, FakeError>) {
        self.result = result
    }

    convenience init(stdout: String, exitCode: Int32 = 0) {
        self.init(.success(CommandResult(standardOutput: stdout, standardError: "", exitCode: exitCode)))
    }

    func run(executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        lock.withLock { invocations.append((executableURL, arguments)) }
        return try result.get()
    }
}

/// A file probe backed by an explicit set of executable paths.
struct FakeFileProbe: FileProbing {
    let executablePaths: Set<String>
    func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

/// A data fetcher returning preconfigured bytes or an error.
struct FakeDataFetcher: DataFetching {
    let result: Result<Data, FakeError>
    func data(from url: URL) async throws -> Data {
        try result.get()
    }
}

/// A transport provider that vends a shared in-memory transport.
final class FakeTransportProvider: TransportProviding, @unchecked Sendable {
    let transport = MockTransport()
    private let lock = NSLock()
    private var _lastSpec: ProcessSpec?

    var lastSpec: ProcessSpec? { lock.withLock { _lastSpec } }

    func makeTransport(for spec: ProcessSpec) throws -> any Transport {
        lock.withLock { _lastSpec = spec }
        return transport
    }
}
