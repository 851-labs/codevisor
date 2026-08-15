enum SidebarOrder: String, CaseIterable {
    case none
    case updated
    case created

    var title: String {
        switch self {
        case .none: return "None"
        case .updated: return "Last updated"
        case .created: return "Created"
        }
    }
}
