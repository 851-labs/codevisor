import Foundation
import Testing
@testable import CodevisorClient

@Suite("Codevisor machine")
struct CodevisorMachineTests {
    @Test("The local machine uses the hostname as its display name")
    func localMachineName() {
        #expect(CodevisorMachine.local.name == ProcessInfo.processInfo.hostName)
    }
}
