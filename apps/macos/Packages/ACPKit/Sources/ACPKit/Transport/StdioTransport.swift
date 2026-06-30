import Foundation

/// Describes how to launch an agent subprocess.
public struct ProcessSpec: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
    }
}

/// A `Transport` backed by a child `Process` communicating over newline-delimited
/// JSON on stdin/stdout. Diagnostic output written by the agent to stderr is
/// surfaced through `stderr` for logging.
public final class StdioTransport: Transport, @unchecked Sendable {
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "com.851labs.acpkit.stdio.write")

    public let incoming: AsyncThrowingStream<Data, any Error>
    private let incomingContinuation: AsyncThrowingStream<Data, any Error>.Continuation

    /// A stream of UTF-8 strings written by the agent to stderr.
    public let stderr: AsyncStream<String>
    private let stderrContinuation: AsyncStream<String>.Continuation

    public init(spec: ProcessSpec) {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.currentDirectoryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.process = process

        (incoming, incomingContinuation) = AsyncThrowingStream.makeStream(of: Data.self)
        (stderr, stderrContinuation) = AsyncStream.makeStream(of: String.self)
    }

    /// Launches the subprocess and begins reading its output.
    public func start() throws {
        let continuation = incomingContinuation
        let stderrContinuation = self.stderrContinuation

        let framerBox = FramerBox()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
                return
            }
            for message in framerBox.append(data) {
                continuation.yield(message)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else { return }
            stderrContinuation.yield(string)
        }

        process.terminationHandler = { _ in
            continuation.finish()
            stderrContinuation.finish()
        }

        try process.run()
    }

    public func send(_ message: Data) async throws {
        let framed = NDJSONFramer.frame(message)
        let handle = stdinPipe.fileHandleForWriting
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                do {
                    try handle.write(contentsOf: framed)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        incomingContinuation.finish()
        stderrContinuation.finish()
    }
}

/// A small reference box so the stdout readability handler can keep mutable
/// framer state across callbacks.
private final class FramerBox: @unchecked Sendable {
    private var framer = NDJSONFramer()
    private let lock = NSLock()

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return framer.append(data)
    }
}
