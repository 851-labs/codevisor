import Foundation

/// ACP JSON-RPC method names.
public enum ACPMethod {
    // Agent methods (client -> agent).
    public static let initialize = "initialize"
    public static let authenticate = "authenticate"
    public static let sessionNew = "session/new"
    public static let sessionLoad = "session/load"
    public static let sessionList = "session/list"
    public static let sessionDelete = "session/delete"
    public static let sessionPrompt = "session/prompt"
    public static let sessionSetMode = "session/set_mode"
    public static let sessionSetConfigOption = "session/set_config_option"
    public static let sessionCancel = "session/cancel"

    // Client methods (agent -> client).
    public static let sessionUpdate = "session/update"
    public static let sessionRequestPermission = "session/request_permission"
    public static let fsReadTextFile = "fs/read_text_file"
    public static let fsWriteTextFile = "fs/write_text_file"
    public static let terminalCreate = "terminal/create"
    public static let terminalOutput = "terminal/output"
    public static let terminalRelease = "terminal/release"
    public static let terminalWaitForExit = "terminal/wait_for_exit"
    public static let terminalKill = "terminal/kill"
}
