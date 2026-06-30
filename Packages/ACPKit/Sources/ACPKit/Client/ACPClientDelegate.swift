import Foundation

/// Handles requests the agent makes back to the client during a session:
/// permission prompts, file system access, and terminal management.
///
/// All methods have default implementations that report the capability as
/// unsupported, so conformers only implement what they advertise in
/// `ClientCapabilities`.
public protocol ACPClientDelegate: AnyObject, Sendable {
    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionResponse
    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse
    func writeTextFile(_ request: WriteTextFileRequest) async throws
    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse
    func terminalOutput(_ request: TerminalRequest) async throws -> TerminalOutputResponse
    func releaseTerminal(_ request: TerminalRequest) async throws
    func waitForTerminalExit(_ request: TerminalRequest) async throws -> WaitForExitResponse
    func killTerminal(_ request: TerminalRequest) async throws
}

public extension ACPClientDelegate {
    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        RequestPermissionResponse(outcome: .cancelled)
    }

    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        throw JSONRPCError.methodNotFound(ACPMethod.fsReadTextFile)
    }

    func writeTextFile(_ request: WriteTextFileRequest) async throws {
        throw JSONRPCError.methodNotFound(ACPMethod.fsWriteTextFile)
    }

    func createTerminal(_ request: CreateTerminalRequest) async throws -> CreateTerminalResponse {
        throw JSONRPCError.methodNotFound(ACPMethod.terminalCreate)
    }

    func terminalOutput(_ request: TerminalRequest) async throws -> TerminalOutputResponse {
        throw JSONRPCError.methodNotFound(ACPMethod.terminalOutput)
    }

    func releaseTerminal(_ request: TerminalRequest) async throws {
        throw JSONRPCError.methodNotFound(ACPMethod.terminalRelease)
    }

    func waitForTerminalExit(_ request: TerminalRequest) async throws -> WaitForExitResponse {
        throw JSONRPCError.methodNotFound(ACPMethod.terminalWaitForExit)
    }

    func killTerminal(_ request: TerminalRequest) async throws {
        throw JSONRPCError.methodNotFound(ACPMethod.terminalKill)
    }
}
