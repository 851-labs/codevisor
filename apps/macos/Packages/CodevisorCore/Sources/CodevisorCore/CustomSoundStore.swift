import AVFoundation
import Foundation

/// Manages user-imported notification sounds. Files the user picks (wav, mp3,
/// m4a, aiff, flac, …) are validated against a maximum duration and converted
/// to a canonical Core Audio format — CAF with 16-bit linear PCM, the safest
/// format for `UNNotificationSound` and `NSSound` alike — inside an
/// app-managed sounds directory. Settings then reference the converted file
/// by absolute path, exactly like the built-in macOS sounds.
public struct CustomSoundStore: Sendable {
    public enum ImportError: Error, LocalizedError, Equatable {
        case unreadableAudio
        case emptyAudio
        case tooLong(seconds: Double)
        case conversionFailed

        public var errorDescription: String? {
            switch self {
            case .unreadableAudio:
                "This file isn't an audio format Codevisor can read. Try a WAV, MP3, M4A, or AIFF file."
            case .emptyAudio:
                "This audio file has no sound in it."
            case .tooLong(let seconds):
                String(
                    format: "This sound is %.1f seconds long. Notification sounds can be at most %.0f seconds.",
                    seconds,
                    CustomSoundStore.maxDuration
                )
            case .conversionFailed:
                "Codevisor couldn't convert this sound. Try a different file."
            }
        }
    }

    /// Notification sounds are short attention cues, and `UNNotificationSound`
    /// truncates long files anyway; cap imports well below that.
    public static let maxDuration: TimeInterval = 5

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init() {
        self.init(directory: Self.defaultDirectory())
    }

    /// The default location for imported sound files:
    /// `Application Support/<variant>/sounds`.
    public static func defaultDirectory() -> URL {
        CodevisorAppVariant.applicationSupportURL()
            .appendingPathComponent("sounds", isDirectory: true)
    }

    /// The converted sounds currently in the store, sorted by name.
    public func availableSounds() -> [URL] {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "caf" }
            .map(\.standardizedFileURL)
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Imports an audio file the user picked: validates it decodes and fits
    /// the duration limit, converts it to CAF/PCM in the store directory, and
    /// returns the converted file's URL. Reads through the security scope
    /// (fileImporter URLs are scoped in the sandbox).
    @discardableResult
    public func importSound(from url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: url)
        } catch {
            throw ImportError.unreadableAudio
        }
        let format = source.processingFormat
        guard source.length > 0, format.sampleRate > 0 else { throw ImportError.emptyAudio }
        let duration = Double(source.length) / format.sampleRate
        guard duration <= Self.maxDuration else { throw ImportError.tooLong(seconds: duration) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = availableDestination(for: url.deletingPathExtension().lastPathComponent)
        do {
            try convert(source, to: destination, format: format)
        } catch {
            // Never leave a half-written file behind for the catalog to list.
            try? FileManager.default.removeItem(at: destination)
            throw (error as? ImportError) ?? ImportError.conversionFailed
        }
        return destination.standardizedFileURL
    }

    /// Deletes an imported sound, along with the private copy prepared for
    /// UserNotifications in `~/Library/Sounds`, if one was made. Callers are
    /// responsible for resetting any setting that referenced the path.
    public func deleteSound(at url: URL) throws {
        let manager = FileManager.default
        try manager.removeItem(at: url)
        if let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let prepared = library
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent(Self.preparedNotificationSoundName(for: url))
            try? manager.removeItem(at: prepared)
        }
    }

    /// The file name used when copying a sound into `~/Library/Sounds` so
    /// UserNotifications can resolve it by name. Shared with the notification
    /// manager so deleting a custom sound also removes its prepared copy.
    public static func preparedNotificationSoundName(for source: URL) -> String {
        let safeBase = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        return "Codevisor-\(safeBase).\(source.pathExtension.lowercased())"
    }

    // MARK: - Conversion

    /// Decodes the source and rewrites it as CAF containing 16-bit linear PCM
    /// at the source's sample rate and channel count. Reading and writing both
    /// use the source's processing format (float32, deinterleaved), so buffers
    /// pass straight through without an explicit converter.
    private func convert(_ source: AVAudioFile, to destination: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw ImportError.conversionFailed
        }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// A destination that won't clobber an existing sound: "Ding.caf",
    /// then "Ding 2.caf", "Ding 3.caf", …
    private func availableDestination(for baseName: String) -> URL {
        let manager = FileManager.default
        let base = baseName.isEmpty ? "Sound" : baseName
        var candidate = directory.appendingPathComponent("\(base).caf")
        var counter = 2
        while manager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).caf")
            counter += 1
        }
        return candidate
    }
}
