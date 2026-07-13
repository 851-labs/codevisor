import Foundation
@testable import CodevisorCore

enum FakeEnvironmentError: Error { case boom }

/// A command runner returning a preconfigured result.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    private let result: Result<CommandResult, FakeEnvironmentError>
    private let lock = NSLock()
    private(set) var invocations: [(URL, [String])] = []

    init(_ result: Result<CommandResult, FakeEnvironmentError>) {
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
