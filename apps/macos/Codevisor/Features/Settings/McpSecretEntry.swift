import Foundation

struct McpSecretEntry: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    let existing: Bool
}
