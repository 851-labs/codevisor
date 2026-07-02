import Foundation
import ACPKit

/// Handles the agent's callbacks to the client: file reads/writes within the
/// project, and tool permission requests.
///
/// Permissions currently auto-approve "allow once" so tool calls proceed; this
/// is the integration point for an interactive permission prompt.
final class AppClientDelegate: ACPClientDelegate, @unchecked Sendable {
    private let fileManager = FileManager.default

    func requestPermission(_ request: RequestPermissionRequest) async -> RequestPermissionResponse {
        if let option = request.options.first(where: { $0.kind == .allowOnce })
            ?? request.options.first(where: { $0.kind == .allowAlways }) {
            return RequestPermissionResponse(outcome: .selected(optionId: option.optionId))
        }
        return RequestPermissionResponse(outcome: .cancelled)
    }

    func readTextFile(_ request: ReadTextFileRequest) async throws -> ReadTextFileResponse {
        let content = try String(contentsOfFile: request.path, encoding: .utf8)
        if let line = request.line.map(Int.init) {
            let lines = content.components(separatedBy: "\n")
            let start = max(0, line - 1)
            let end = request.limit.map { min(lines.count, start + Int($0)) } ?? lines.count
            guard start < lines.count else { return ReadTextFileResponse(content: "") }
            return ReadTextFileResponse(content: lines[start..<end].joined(separator: "\n"))
        }
        return ReadTextFileResponse(content: content)
    }

    func writeTextFile(_ request: WriteTextFileRequest) async throws {
        try request.content.write(toFile: request.path, atomically: true, encoding: .utf8)
    }
}
