import Foundation

public enum HerdManAppVariant: Sendable {
    public static let productionPort = 49_361
    public static let developmentPort = 49_362

    public static var isDevelopment: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static var localServerPort: Int {
        isDevelopment ? developmentPort : productionPort
    }

    public static var applicationSupportDirectoryName: String {
        isDevelopment ? "HerdMan Development" : "HerdMan"
    }

    public static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
