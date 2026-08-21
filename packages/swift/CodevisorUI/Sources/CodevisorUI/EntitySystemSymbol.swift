import CodevisorCore

/// Fixed Apple-platform symbols for domain entities. Renderer-specific icon
/// names stay in the UI layer and never enter models, APIs, or persistence.
public enum EntitySystemSymbol {
    public static let project = "folder.fill"
    public static let projectList = "folder"
    public static let workspace = "square.grid.2x2.fill"

    public static func machine(_ machine: CodevisorMachine) -> String {
        if machine.isLocal { return "desktopcomputer" }
        if machine.isCloud { return "globe" }
        return "network"
    }
}
