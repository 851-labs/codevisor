import Foundation
#if os(macOS)
import LocalAuthentication
#endif
import Security
import Testing
@testable import CodevisorCore

@Suite("Keychain credential stores")
struct KeychainCredentialStoreTests {
    @Test("Cloud credentials read from the data-protection Keychain once")
    func cloudReadsModernValueOnce() throws {
        let keychain = FakeKeychain()
        keychain.put("token", service: "cloud", account: "session-token", modern: true)
        let store = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)

        #expect(try store.token() == "token")
        #expect(try store.token() == "token")
        #expect(keychain.copyCount(service: "cloud", account: "session-token", modern: true) == 1)
        #expect(keychain.legacyCopyCount == 0)
    }

    #if os(macOS)
    @Test("An accessible login-Keychain value migrates silently")
    func legacyValueMigratesSilently() throws {
        let keychain = FakeKeychain()
        keychain.put("legacy-token", service: "cloud", account: "session-token", modern: false)
        let store = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)

        #expect(try store.token() == "legacy-token")
        #expect(keychain.value(service: "cloud", account: "session-token", modern: true) == "legacy-token")
        let migrationWasNonInteractive = keychain.legacyQueries.allSatisfy(\.forbidsInteraction)
        #expect(migrationWasNonInteractive)

        // A new process/store now finds the migrated value directly and does
        // not return to the login Keychain.
        let relaunched = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)
        #expect(try relaunched.token() == "legacy-token")
        #expect(keychain.legacyCopyCount == 1)
    }

    @Test("A protected legacy value never asks for authorization")
    func protectedLegacyValueDoesNotPrompt() throws {
        let keychain = FakeKeychain()
        keychain.legacyReadStatus = errSecInteractionNotAllowed
        let store = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)

        #expect(try store.token() == nil)
        #expect(try store.token() == nil)
        #expect(keychain.legacyCopyCount == 1)
        let lookupWasNonInteractive = keychain.legacyQueries.allSatisfy(\.forbidsInteraction)
        #expect(lookupWasNonInteractive)
    }

    @Test("Removing a migrated value cannot resurrect its legacy copy")
    func removalTombstonesLegacyValue() throws {
        let keychain = FakeKeychain()
        keychain.put("legacy-token", service: "cloud", account: "session-token", modern: false)
        let store = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)

        #expect(try store.token() == "legacy-token")
        try store.removeToken()

        let relaunched = KeychainCloudCredentialStore(service: "cloud", operations: keychain.operations)
        #expect(try relaunched.token() == nil)
        #expect(keychain.legacyCopyCount == 1)
    }
    #endif

    @Test("Machine credentials use the data-protection Keychain")
    func machineCredentialsUseModernStore() throws {
        let keychain = FakeKeychain()
        let store = KeychainMachineCredentialStore(service: "machine", operations: keychain.operations)

        try store.saveToken("machine-token", forMachineID: "machine-1")
        #expect(try store.token(forMachineID: "machine-1") == "machine-token")
        #expect(keychain.value(service: "machine", account: "machine-1", modern: true) == "machine-token")
        let allMutationsWereModern = keychain.mutationQueries.allSatisfy(\.modern)
        #expect(allMutationsWereModern)
    }
}

private final class FakeKeychain: @unchecked Sendable {
    struct QueryRecord: Sendable {
        let service: String
        let account: String
        let modern: Bool
        let forbidsInteraction: Bool
    }

    private struct Item: Hashable {
        let service: String
        let account: String
        let modern: Bool
    }

    private let lock = NSLock()
    private var items: [Item: Data] = [:]
    private var copied: [QueryRecord] = []
    private var mutated: [QueryRecord] = []
    var legacyReadStatus: OSStatus?

    var operations: KeychainOperations {
        KeychainOperations(
            copyMatching: { [self] query in copy(query) },
            update: { [self] query, attributes in update(query, attributes) },
            add: { [self] attributes in add(attributes) },
            delete: { [self] query in delete(query) }
        )
    }

    var legacyQueries: [QueryRecord] {
        lock.withLock { copied.filter { !$0.modern } }
    }

    var legacyCopyCount: Int {
        legacyQueries.count
    }

    var mutationQueries: [QueryRecord] {
        lock.withLock { mutated }
    }

    func put(_ value: String, service: String, account: String, modern: Bool) {
        lock.withLock {
            items[Item(service: service, account: account, modern: modern)] = Data(value.utf8)
        }
    }

    func value(service: String, account: String, modern: Bool) -> String? {
        lock.withLock {
            items[Item(service: service, account: account, modern: modern)]
                .map { String(decoding: $0, as: UTF8.self) }
        }
    }

    func copyCount(service: String, account: String, modern: Bool) -> Int {
        lock.withLock {
            copied.count { $0.service == service && $0.account == account && $0.modern == modern }
        }
    }

    private func copy(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        let record = queryRecord(query)
        return lock.withLock {
            copied.append(record)
            if !record.modern, let legacyReadStatus {
                return (legacyReadStatus, nil)
            }
            guard let value = items[item(query)] else {
                return (errSecItemNotFound, nil)
            }
            return (errSecSuccess, value)
        }
    }

    private func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        let record = queryRecord(query)
        return lock.withLock {
            mutated.append(record)
            let key = item(query)
            guard items[key] != nil else { return errSecItemNotFound }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            return errSecSuccess
        }
    }

    private func add(_ attributes: [String: Any]) -> OSStatus {
        let record = queryRecord(attributes)
        return lock.withLock {
            mutated.append(record)
            let key = item(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
            items[key] = data
            return errSecSuccess
        }
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        let record = queryRecord(query)
        return lock.withLock {
            mutated.append(record)
            return items.removeValue(forKey: item(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private func item(_ query: [String: Any]) -> Item {
        let record = queryRecord(query)
        return Item(service: record.service, account: record.account, modern: record.modern)
    }

    private func queryRecord(_ query: [String: Any]) -> QueryRecord {
        let service = query[kSecAttrService as String] as? String ?? ""
        let account = query[kSecAttrAccount as String] as? String ?? ""
        let modern = query[kSecUseDataProtectionKeychain as String] as? Bool == true
        #if os(macOS)
        let forbidsInteraction =
            (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true
        #else
        let forbidsInteraction = false
        #endif
        return QueryRecord(
            service: service,
            account: account,
            modern: modern,
            forbidsInteraction: forbidsInteraction
        )
    }
}
