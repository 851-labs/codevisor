import Foundation
import Testing

@testable import CodevisorClient

@Suite("Connection loss reporting")
struct ConnectionLossReportingTests {
  @Test("A request that gets no response reports its machine's connection lost")
  func unansweredRequestReportsLoss() async {
    let (client, reports) = client(failingWith: .failure(URLError(.networkConnectionLost)))

    await #expect(throws: URLError.self) { try await client.listProjects() }

    #expect(reports.machineIds == ["studio"])
  }

  @Test("A request the server answers, even with an error, leaves the connection alone")
  func answeredRequestDoesNotReportLoss() async {
    let (client, reports) = client(failingWith: .status(503))

    await #expect(throws: CodevisorServerClientError.self) { try await client.listProjects() }

    #expect(reports.machineIds.isEmpty)
  }

  @Test("A cancelled request leaves the connection alone")
  func cancelledRequestDoesNotReportLoss() async {
    let (client, reports) = client(failingWith: .failure(URLError(.cancelled)))

    await #expect(throws: URLError.self) { try await client.listProjects() }

    #expect(reports.machineIds.isEmpty)
  }

  private func client(failingWith outcome: FailingTransport.Outcome) -> (CodevisorServerClient, LossReports) {
    let gate = ServerRequestGate()
    let reports = LossReports()
    gate.onConnectionLost { reports.record($0) }
    let client = CodevisorServerClient(
      config: .init(requestTransport: FailingTransport(outcome: outcome)), requestGate: gate, machineId: "studio")
    return (client, reports)
  }
}

private struct FailingTransport: ServerRequestTransport {
  enum Outcome: Sendable {
    case failure(URLError)
    case status(Int)
  }

  let outcome: Outcome

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    switch outcome {
    case let .failure(error):
      throw error
    case let .status(code):
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
  }

  func stream(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, any Error>) {
    throw URLError(.unsupportedURL)
  }
}

private final class LossReports: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var machineIds: [String] { lock.withLock { recorded } }

  func record(_ machineId: String) {
    lock.withLock { recorded.append(machineId) }
  }
}
