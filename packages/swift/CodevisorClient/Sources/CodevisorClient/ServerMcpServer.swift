import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerMcpServer: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var kind: String?
  public var canEdit: Bool?
  public var canRemove: Bool?
  public var transport: String
  public var url: String?
  public var command: String?
  public var args: [String]
  public var headerNames: [String]?
  public var environmentNames: [String]?
  public var enabled: Bool
  public var authType: String
  public var oauthScope: String?
  public var connectionState: String
  public var toolCount: Int
  public var detail: String?
  public var catalogId: String?
  public var catalogVersion: String?
  public var capabilities: ServerPluginCapabilities?
  public var ageRating: Int?
  public var createdAt: String
  public var updatedAt: String

  public var capabilityDigest: ServerPluginCapabilities? {
    guard let capabilities, !capabilities.isEmpty else { return nil }
    return capabilities
  }

  public var awaitsAuthorization: Bool {
    connectionState == "needsAuthorization" || (authType == "oauth" && connectionState != "connected")
  }

  public var isBundledPlugin: Bool {
    catalogId != nil && command == "codevisor-plugin"
  }

  public var isBuiltIn: Bool {
    switch kind {
    case "browserUse", "computerUse", "codevisor": true
    default: false
    }
  }
}

public struct ServerBrowserUseConfiguration: Codable, Equatable, Sendable {
  public var chromeAvailable: Bool
  public var chromeConnected: Bool
  public var managedAvailable: Bool
  public var extensionFlowSupported: Bool?
  public var extensionSetupMode: String?
  public var unpackedExtensionInstalled: Bool?
  public var developmentExtensionPath: String?

  public var supportsExtensionFlow: Bool { extensionFlowSupported ?? true }
  public var installsFromWebStore: Bool { extensionSetupMode == "webStore" }

  public init(
    chromeAvailable: Bool,
    chromeConnected: Bool,
    managedAvailable: Bool,
    extensionFlowSupported: Bool? = nil,
    extensionSetupMode: String? = nil,
    unpackedExtensionInstalled: Bool? = nil,
    developmentExtensionPath: String? = nil
  ) {
    self.chromeAvailable = chromeAvailable
    self.chromeConnected = chromeConnected
    self.managedAvailable = managedAvailable
    self.extensionFlowSupported = extensionFlowSupported
    self.extensionSetupMode = extensionSetupMode
    self.unpackedExtensionInstalled = unpackedExtensionInstalled
    self.developmentExtensionPath = developmentExtensionPath
  }
}

public struct ServerMcpTool: Codable, Equatable, Identifiable, Sendable {
  public var serverId: String
  public var serverName: String
  public var name: String
  public var title: String?
  public var description: String?
  public var id: String { "\(serverId)/\(name)" }
}

public struct ServerMcpOAuthStart: Codable, Equatable, Sendable {
  public var authorizationUrl: String
}

public struct ServerMcpAuthDetection: Codable, Equatable, Sendable {
  public var authType: String
  public var detail: String
  public var suggestedName: String? = nil
}
