import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

@Suite("CodevisorAppVariant")
struct AppVariantTests {
  @Test("Parses the dev cloud configuration from launch environment")
  func developmentCloudParsing() {
    let full = CodevisorAppVariant.developmentCloud(from: [
      "CODEVISOR_DEV_CLOUD_URL": "http://127.0.0.1:8787"
    ])
    #expect(full == CodevisorAppVariant.DevelopmentCloud(url: URL(string: "http://127.0.0.1:8787")!))

    #expect(CodevisorAppVariant.developmentCloud(from: [:]) == nil)
    #expect(CodevisorAppVariant.developmentCloud(from: ["CODEVISOR_DEV_CLOUD_URL": ""]) == nil)
  }

  @Test("Recovers dev instance configuration when relaunched outside the runner")
  func resolvesDevLaunchEnvironment() {
    let configured = [
      "CODEVISOR_DEV_INSTANCE_ID": "lingonberry-abc",
      "CODEVISOR_DEV_DATA_DIR": "/tmp/instance",
      "HERDMAN_DEV_PORT": "1234",
      "PATH": "/usr/bin",
    ]

    let fromRunner = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: configured,
      stashed: ["CODEVISOR_DEV_DATA_DIR": "/tmp/old"]
    )
    #expect(fromRunner.environment == configured)
    #expect(
      fromRunner.stash == [
        "CODEVISOR_DEV_INSTANCE_ID": "lingonberry-abc",
        "CODEVISOR_DEV_DATA_DIR": "/tmp/instance",
        "HERDMAN_DEV_PORT": "1234",
      ])

    let reopened = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: ["PATH": "/usr/bin"],
      stashed: fromRunner.stash
    )
    #expect(reopened.environment["CODEVISOR_DEV_INSTANCE_ID"] == "lingonberry-abc")
    #expect(reopened.environment["CODEVISOR_DEV_DATA_DIR"] == "/tmp/instance")
    #expect(reopened.environment["PATH"] == "/usr/bin")
    #expect(reopened.stash == nil)

    let bare = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: ["PATH": "/usr/bin"],
      stashed: nil
    )
    #expect(bare.environment == ["PATH": "/usr/bin"])
    #expect(bare.stash == nil)
  }
}
