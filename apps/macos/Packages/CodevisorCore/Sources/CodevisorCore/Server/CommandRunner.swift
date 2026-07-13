import Foundation

/// The result of running a command to completion.
public struct CommandResult: Sendable, Equatable {
    public var standardOutput: String
    public var standardError: String
    public var exitCode: Int32

    public init(standardOutput: String, standardError: String, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

/// Runs a command to completion and returns its captured output.
///
/// Abstracted so discovery logic can be tested without spawning processes.
public protocol CommandRunner: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult
}

/// A `CommandRunner` backed by `Foundation.Process`.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Read pipes on background queues to avoid deadlock on large output.
        async let outData = readToEnd(outPipe.fileHandleForReading)
        async let errData = readToEnd(errPipe.fileHandleForReading)
        let (out, err) = await (outData, errData)
        process.waitUntilExit()

        return CommandResult(
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    private func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data: Data
                do {
                    data = try handle.readToEnd() ?? Data()
                } catch {
                    // Empty output keeps the command result usable; the read
                    // failure must not masquerade as a silent command.
                    Log.server.error(
                        "Failed to read process output: \(String(describing: error), privacy: .public)"
                    )
                    data = Data()
                }
                continuation.resume(returning: data)
            }
        }
    }
}
