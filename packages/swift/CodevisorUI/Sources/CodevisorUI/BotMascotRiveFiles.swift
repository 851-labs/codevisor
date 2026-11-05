import CodevisorCore
import Foundation
@preconcurrency import RiveRuntime

@MainActor
final class BotMascotRiveFiles {
  static let shared = BotMascotRiveFiles()

  private var worker: Task<Worker, any Error>?
  private var files: [String: Task<File, any Error>] = [:]
  private var values: [ServerBotMascotArt: Task<BotMascotRiveValues, any Error>] = [:]

  func file(serverId: String, client: any CodevisorServerClienting, mascot: ServerBotMascot) async throws -> File {
    let task = files[serverId] ?? startFile(serverId: serverId, client: client, mascot: mascot)
    do {
      return try await task.value
    } catch {
      files[serverId] = nil
      throw error
    }
  }

  func values(for mascot: ServerBotMascot, client: any CodevisorServerClienting) async throws -> BotMascotRiveValues {
    let art = ServerBotMascotArt(mascot, .riveValues)
    let task = values[art] ?? startValues(art, client: client)
    do {
      return try await task.value
    } catch {
      values[art] = nil
      throw error
    }
  }

  private func startFile(
    serverId: String, client: any CodevisorServerClienting, mascot: ServerBotMascot
  ) -> Task<File, any Error> {
    let task = Task {
      let data = try await client.botMascotArt(ServerBotMascotArt(mascot, .rive))
      return try await File(source: .data(data), worker: try await sharedWorker())
    }
    files[serverId] = task
    return task
  }

  private func startValues(
    _ art: ServerBotMascotArt, client: any CodevisorServerClienting
  ) -> Task<BotMascotRiveValues, any Error> {
    let task = Task { try BotMascotRiveValues(json: try await client.botMascotArt(art)) }
    values[art] = task
    return task
  }

  private func sharedWorker() async throws -> Worker {
    let task = worker ?? Task { try await Worker() }
    worker = task
    return try await task.value
  }
}
