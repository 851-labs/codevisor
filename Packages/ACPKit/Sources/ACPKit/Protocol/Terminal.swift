import Foundation

/// `terminal/create` request params.
public struct CreateTerminalRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var command: String
    public var args: [String]?
    public var env: [EnvVariable]?
    public var cwd: String?
    public var outputByteLimit: UInt64?

    public init(
        sessionId: String,
        command: String,
        args: [String]? = nil,
        env: [EnvVariable]? = nil,
        cwd: String? = nil,
        outputByteLimit: UInt64? = nil
    ) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.outputByteLimit = outputByteLimit
    }
}

/// `terminal/create` response.
public struct CreateTerminalResponse: Sendable, Codable, Equatable {
    public var terminalId: String

    public init(terminalId: String) {
        self.terminalId = terminalId
    }
}

/// The exit status of a terminal command.
public struct TerminalExitStatus: Sendable, Codable, Equatable {
    public var exitCode: UInt32?
    public var signal: String?

    public init(exitCode: UInt32? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}

/// A request referencing an existing terminal (used by output/kill/release/wait).
public struct TerminalRequest: Sendable, Codable, Equatable {
    public var sessionId: String
    public var terminalId: String

    public init(sessionId: String, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }
}

/// `terminal/output` response.
public struct TerminalOutputResponse: Sendable, Codable, Equatable {
    public var output: String
    public var truncated: Bool
    public var exitStatus: TerminalExitStatus?

    public init(output: String, truncated: Bool, exitStatus: TerminalExitStatus? = nil) {
        self.output = output
        self.truncated = truncated
        self.exitStatus = exitStatus
    }
}

/// `terminal/wait_for_exit` response.
public struct WaitForExitResponse: Sendable, Codable, Equatable {
    public var exitCode: UInt32?
    public var signal: String?

    public init(exitCode: UInt32? = nil, signal: String? = nil) {
        self.exitCode = exitCode
        self.signal = signal
    }
}
