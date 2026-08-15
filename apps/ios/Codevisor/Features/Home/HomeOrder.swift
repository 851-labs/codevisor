import Foundation

/// Agent ordering only. Project and workspace containers keep independent
/// manual orders regardless of this selection.
enum HomeOrder: String, CaseIterable {
    case updated
    case created
    case none

    var title: String {
        switch self {
        case .none: "None"
        case .updated: "Last updated"
        case .created: "Created"
        }
    }
}
