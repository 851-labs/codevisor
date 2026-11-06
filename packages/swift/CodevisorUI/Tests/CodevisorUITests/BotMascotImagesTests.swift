import CodevisorClient
import CodevisorCore
import CodevisorTestSupport
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CodevisorUI

@Suite("Bot mascot images")
@MainActor
struct BotMascotImagesTests {
  private let art = ServerBotMascotArt(ServerBotMascot(color: "mint", hat: "beanie", eyewear: "none"), .portrait)

  @Test("A failed download is retried with the machine's current client, so a machine that comes back is reached")
  func retriesWithCurrentClient() async {
    let clock = TestClock()
    let images = BotMascotImages()
    let unreachable = MascotImageClient(failures: 1)
    let reachable = MascotImageClient(failures: 0)
    let machine = MachineClientSlot(unreachable)
    let retry = retry(clock: clock) { machine.client }

    let load = Task { await images.load(art, retrying: retry) }
    await clock.waitForSleep(.seconds(1))
    #expect(images.image(for: art) == nil)

    machine.client = reachable
    clock.advance(by: .seconds(1))
    await load.value

    #expect(images.image(for: art) != nil)
    #expect(unreachable.requests == 1)
    #expect(reachable.requests == 1)
  }

  @Test("A view that goes away mid-download still caches the image for the next view")
  func leavingViewKeepsDownload() async {
    let images = BotMascotImages()
    let client = MascotImageClient(failures: 0, gated: true)
    let retry = retry { client }

    let leaving = Task { await images.load(art, retrying: retry) }
    await client.requested.wait()
    leaving.cancel()
    client.release.signal()
    await leaving.value
    await images.load(art, retrying: retry)

    #expect(images.image(for: art) != nil)
    #expect(client.requests == 1)
  }

  @Test("Art the server refuses isn't asked for again, so older servers without loops aren't polled")
  func refusedArtIsNotRetried() async {
    let images = BotMascotImages()
    let client = MascotImageClient(failures: 1, failure: .httpStatus(404, "Not found"))

    await images.load(art, retrying: retry { client })

    #expect(images.image(for: art) == nil)
    #expect(client.requests == 1)
  }

  private func retry(
    clock: TestClock = TestClock(), client: @escaping @MainActor () -> any CodevisorServerClienting
  ) -> MachineRetry {
    let machines = MachineController(
      store: InMemoryStore(), projectList: ProjectListModel(), clientFactory: { _ in client() })
    return MachineRetry(
      machineId: CodevisorMachine.local.id, machines: machines, policy: RetryPolicy(clock: clock, jitter: 0))
  }
}

@MainActor
private final class MachineClientSlot {
  var client: any CodevisorServerClienting

  init(_ client: any CodevisorServerClienting) {
    self.client = client
  }
}

private final class MascotImageClient: CodevisorServerClienting, @unchecked Sendable {
  let requested = TestSignal()
  let release = TestSignal()

  private let lock = NSLock()
  private let gated: Bool
  private let failure: CodevisorServerClientError
  private var failures: Int
  private var _requests = 0

  init(failures: Int, gated: Bool = false, failure: CodevisorServerClientError = .invalidResponse) {
    self.failures = failures
    self.gated = gated
    self.failure = failure
  }

  var requests: Int { lock.withLock { _requests } }

  func botMascotArt(_ art: ServerBotMascotArt) async throws -> Data {
    let fails = recordRequest()
    requested.signal()
    if gated { await release.cancellableWait() }
    try Task.checkCancellation()
    if fails { throw failure }
    return Self.png
  }

  private func recordRequest() -> Bool {
    lock.withLock {
      _requests += 1
      failures -= 1
      return failures >= 0
    }
  }

  private static let png: Data = {
    let context = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }()

  func health() async throws -> ServerHealth { throw CodevisorServerClientError.invalidResponse }
  func info() async throws -> ServerInfo { throw CodevisorServerClientError.invalidResponse }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    throw CodevisorServerClientError.invalidResponse
  }
  func listProjects() async throws -> [ServerProject] { [] }
  func listSessions() async throws -> [ServerSession] { [] }
  func listHarnesses() async throws -> [ServerHarness] { [] }
  func latestShellEventCursor() async throws -> Int { 0 }
  func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
  func navigationSnapshot() async throws -> ServerNavigationSnapshot {
    ServerNavigationSnapshot(eventCursor: 0, projects: [], sessions: [], workspaces: [], panes: [])
  }
  func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
    AsyncThrowingStream { _ in }
  }
  func upsertProject(_ project: Project) async throws -> ServerProject {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteProject(id: UUID) async throws {}
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession {
    throw CodevisorServerClientError.invalidResponse
  }
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    throw CodevisorServerClientError.invalidResponse
  }
  func deleteSession(id: UUID) async throws {}
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
