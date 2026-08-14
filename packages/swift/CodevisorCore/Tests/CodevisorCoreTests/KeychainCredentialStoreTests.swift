import Foundation
import Security
import Testing
@testable import CodevisorCore

@Suite("Keychain credential stores")
struct KeychainCredentialStoreTests {
    @Test("Released builds retain the existing credential service names")
    func releasedServiceNamesRemainStable() {
        let machine = KeychainCredentialServices.scopedService(
            productionService: KeychainCredentialServices.productionMachine,
            isDevelopment: false,
            developmentInstanceID: "ignored",
            bundleIdentifier: "com.example.ignored"
        )
        let cloud = KeychainCredentialServices.scopedService(
            productionService: KeychainCredentialServices.productionCloud,
            isDevelopment: false,
            developmentInstanceID: "ignored",
            bundleIdentifier: "com.example.ignored"
        )

        #expect(machine == "com.851labs.Codevisor.machine-token")
        #expect(cloud == "com.851labs.Codevisor.cloud-session")
    }

    @Test("Development credentials are isolated by app instance and purpose")
    func developmentServicesAreIsolated() {
        let machineA = scopedDevelopmentService(
            KeychainCredentialServices.productionMachine,
            instanceID: "worktree-a"
        )
        let machineB = scopedDevelopmentService(
            KeychainCredentialServices.productionMachine,
            instanceID: "worktree-b"
        )
        let cloudA = scopedDevelopmentService(
            KeychainCredentialServices.productionCloud,
            instanceID: "worktree-a"
        )

        #expect(machineA == "com.851labs.Codevisor.machine-token.development.worktree-a")
        #expect(machineA != machineB)
        #expect(machineA != cloudA)
    }

    @Test("A bare development launch falls back to its bundle identifier")
    func developmentServiceFallsBackToBundleIdentifier() {
        let service = KeychainCredentialServices.scopedService(
            productionService: KeychainCredentialServices.productionCloud,
            isDevelopment: true,
            developmentInstanceID: "  ",
            bundleIdentifier: "com.851labs.Codevisor.Development.abc123"
        )

        #expect(
            service
                == "com.851labs.Codevisor.cloud-session.development.com.851labs.Codevisor.Development.abc123"
        )
    }

    @Test("Machine and cloud credentials share platform-default Keychain behavior")
    func credentialStoresSharePlatformKeychainBehavior() throws {
        let keychain = FakeKeychain()
        let machine = KeychainMachineCredentialStore(
            service: "machine.dev-a",
            operations: keychain.operations
        )
        let cloud = KeychainCloudCredentialStore(
            service: "cloud.dev-a",
            operations: keychain.operations
        )

        try machine.saveToken("machine-token", forMachineID: "machine-1")
        try cloud.saveToken("cloud-token")
        try cloud.saveServerURL(URL(string: "https://cloud.example")!)

        #expect(try machine.token(forMachineID: "machine-1") == "machine-token")
        #expect(try cloud.token() == "cloud-token")
        #expect(try cloud.serverURL() == URL(string: "https://cloud.example"))
        #expect(keychain.value(service: "machine.dev-a", account: "machine-1") == "machine-token")
        #expect(keychain.value(service: "cloud.dev-a", account: "session-token") == "cloud-token")
        #expect(keychain.records.allSatisfy { !$0.usesDataProtectionKeychain })

        try machine.removeToken(forMachineID: "machine-1")
        try cloud.removeToken()
        #expect(try machine.token(forMachineID: "machine-1") == nil)
        #expect(try cloud.token() == nil)
    }

    private func scopedDevelopmentService(
        _ productionService: String,
        instanceID: String
    ) -> String {
        KeychainCredentialServices.scopedService(
            productionService: productionService,
            isDevelopment: true,
            developmentInstanceID: instanceID,
            bundleIdentifier: "com.example.fallback"
        )
    }
}

private final class FakeKeychain: @unchecked Sendable {
    struct QueryRecord: Sendable {
        let service: String
        let account: String
        let usesDataProtectionKeychain: Bool
    }

    private struct Item: Hashable {
        let service: String
        let account: String
    }

    private let lock = NSLock()
    private var items: [Item: Data] = [:]
    private var recordedQueries: [QueryRecord] = []

    var operations: KeychainOperations {
        KeychainOperations(
            copyMatching: { [self] query in copy(query) },
            update: { [self] query, attributes in update(query, attributes) },
            add: { [self] attributes in add(attributes) },
            delete: { [self] query in delete(query) }
        )
    }

    var records: [QueryRecord] {
        lock.withLock { recordedQueries }
    }

    func value(service: String, account: String) -> String? {
        lock.withLock {
            items[Item(service: service, account: account)]
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    private func copy(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        lock.withLock {
            recordedQueries.append(record(query))
            guard let value = items[item(query)] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, value)
        }
    }

    private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            recordedQueries.append(record(query))
            let key = item(query)
            guard items[key] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            return errSecSuccess
        }
    }

    private func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            recordedQueries.append(record(attributes))
            let key = item(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            return errSecSuccess
        }
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            recordedQueries.append(record(query))
            return items.removeValue(forKey: item(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private func item(_ query: [String: Any]) -> Item {
        Item(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? ""
        )
    }

    private func record(_ query: [String: Any]) -> QueryRecord {
        QueryRecord(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? "",
            usesDataProtectionKeychain:
                query[kSecUseDataProtectionKeychain as String] as? Bool == true
        )
    }
}
