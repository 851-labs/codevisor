import CodevisorCore
import Darwin
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

public enum CommandRunnerError: LocalizedError, Equatable {
  case timedOut(String)

  public var errorDescription: String? {
    switch self {
    case let .timedOut(executable):
      "The command \(executable) timed out."
    }
  }
}

public extension CommandRunner {
  /// Runs a command with a hard deadline, even if it ignores cancellation.
  /// Unstructured tasks let the deadline return without waiting for the
  /// losing command; cancellation still terminates a ProcessCommandRunner child.
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?,
    timeout: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws -> CommandResult {
    try Task.checkCancellation()
    let outcome = StartupOutcome<CommandResult>()
    let worker = Task {
      do {
        outcome.resolve(
          .success(
            try await run(
              executableURL: executableURL, arguments: arguments, environment: environment
            )))
      } catch { outcome.resolve(.failure(error)) }
    }
    let timer = Task {
      do {
        try await sleep(timeout)
        try Task.checkCancellation()
        outcome.resolve(.failure(CommandRunnerError.timedOut(executableURL.path)))
      } catch { /* The command finished first. */  }
    }
    defer { worker.cancel(); timer.cancel() }
    return try await withTaskCancellationHandler {
      try await outcome.value
    } onCancel: {
      outcome.resolve(.failure(CancellationError()))
    }
  }
}

/// A `CommandRunner` backed by `Foundation.Process`.
public struct ProcessCommandRunner: CommandRunner {
  private let onStart: @Sendable () -> Void
  private let onExit: @Sendable () -> Void

  public init(
    onStart: @escaping @Sendable () -> Void = {},
    onExit: @escaping @Sendable () -> Void = {}
  ) {
    self.onStart = onStart
    self.onExit = onExit
  }

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

    let cancellation = ProcessCancellationController(process: process)
    // Subscribe before launch and buffer an immediate exit, including a
    // short-lived launchctl command that finishes before the waiter starts.
    // This avoids a blocking wait on another thread's Foundation run loop.
    let (exits, exitContinuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { finished in
      cancellation.markFinished()
      exitContinuation.yield(finished.terminationStatus)
      exitContinuation.finish()
      onExit()
    }
    defer { process.terminationHandler = nil; exitContinuation.finish() }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      do {
        try process.run()
      } catch {
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        throw error
      }
      cancellation.markStarted()
      onStart()

      // The child inherited duplicates of these descriptors. Closing
      // the parent's writers guarantees readToEnd observes EOF even
      // when Foundation retains the Pipe objects until this call ends.
      try? outPipe.fileHandleForWriting.close()
      try? errPipe.fileHandleForWriting.close()

      // Drain both pipes while the process runs so output larger than a
      // pipe buffer cannot deadlock the child.
      async let outData = readToEnd(outPipe.fileHandleForReading)
      async let errData = readToEnd(errPipe.fileHandleForReading)
      var iterator = exits.makeAsyncIterator()
      guard let exitCode = await iterator.next() else { throw CancellationError() }
      let (out, err) = await (outData, errData)
      try Task.checkCancellation()

      return CommandResult(
        standardOutput: String(decoding: out, as: UTF8.self),
        standardError: String(decoding: err, as: UTF8.self),
        exitCode: exitCode
      )
    } onCancel: {
      cancellation.cancel()
    }
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

/// Bridges cooperative Swift cancellation to Foundation.Process. SIGTERM is
/// normally sufficient for launchctl and shell probes; SIGKILL is a bounded
/// fallback for a child that ignores termination.
private final class ProcessCancellationController: @unchecked Sendable {
  private let process: Process
  private let lock = NSLock()
  private var started = false
  private var finished = false
  private var cancellationRequested = false
  private var terminationSent = false

  init(process: Process) {
    self.process = process
  }

  func markStarted() {
    let shouldTerminate = lock.withLock {
      started = true
      return requestTerminationIfNeeded()
    }
    if shouldTerminate {
      terminate()
    }
  }

  func markFinished() {
    lock.withLock {
      finished = true
    }
  }

  func cancel() {
    let shouldTerminate = lock.withLock {
      cancellationRequested = true
      return requestTerminationIfNeeded()
    }
    if shouldTerminate {
      terminate()
    }
  }

  private func requestTerminationIfNeeded() -> Bool {
    guard cancellationRequested, started, !finished, !terminationSent else {
      return false
    }
    terminationSent = true
    return true
  }

  private func terminate() {
    if process.isRunning {
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
      let shouldKill = lock.withLock {
        started && !finished && process.isRunning
      }
      if shouldKill {
        Darwin.kill(process.processIdentifier, SIGKILL)
      }
    }
  }
}
