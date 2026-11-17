import Foundation
import Testing
@testable import CodevisorUI

struct HandlerIdentityTests {
  @Test("Handlers built from equal sources are the same handler, whatever closure they carry")
  func equalSourcesMatch() {
    let source = UUID()
    let first = OpenFileDocumentAction(identity: HandlerIdentity(source)) { _, _ in true }
    let second = OpenFileDocumentAction(identity: HandlerIdentity(source)) { _, _ in false }

    #expect(first == second)
  }

  @Test(
    "Handlers built from different sources are different handlers",
    arguments: [
      (HandlerIdentity(1), HandlerIdentity(2)),
      (HandlerIdentity(1), HandlerIdentity("1")),
      (HandlerIdentity.unique, HandlerIdentity.unique),
    ])
  func differentSourcesDiffer(first: HandlerIdentity, second: HandlerIdentity) {
    let firstAction = OpenFileDocumentAction(identity: first) { _, _ in true }
    let secondAction = OpenFileDocumentAction(identity: second) { _, _ in true }

    #expect(firstAction != secondAction)
  }
}
