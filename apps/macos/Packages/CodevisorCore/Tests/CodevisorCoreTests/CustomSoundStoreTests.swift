import AVFoundation
import Foundation
import Testing

@testable import CodevisorCore

@Suite("CustomSoundStore")
struct CustomSoundStoreTests {
    private let workDirectory: URL
    private let store: CustomSoundStore

    init() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-customsound-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        store = CustomSoundStore(directory: workDirectory.appendingPathComponent("sounds", isDirectory: true))
    }

    /// Writes a mono 440Hz sine fixture in the given container/format.
    private func makeFixture(
        named name: String,
        duration: Double,
        sampleRate: Double = 44_100,
        compressed: Bool = false
    ) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CustomSoundStore.ImportError.conversionFailed
        }
        let settings: [String: Any] = compressed
            ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1
            ]
            : [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CustomSoundStore.ImportError.conversionFailed
        }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) {
                channel[frame] = sinf(Float(frame) * 2 * .pi * 440 / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
        return url
    }

    @Test("Importing a wav produces a playable caf with the same duration")
    func importConvertsToCaf() throws {
        let source = try makeFixture(named: "Ding.wav", duration: 1.5)
        let imported = try store.importSound(from: source)

        #expect(imported.pathExtension == "caf")
        #expect(imported.deletingPathExtension().lastPathComponent == "Ding")
        #expect(store.availableSounds() == [imported])

        let converted = try AVAudioFile(forReading: imported)
        let duration = Double(converted.length) / converted.processingFormat.sampleRate
        #expect(abs(duration - 1.5) < 0.01)
    }

    @Test("Compressed sources (m4a) decode and convert to caf")
    func importsCompressedAudio() throws {
        let source = try makeFixture(named: "Chime.m4a", duration: 2, compressed: true)
        let imported = try store.importSound(from: source)

        #expect(imported.pathExtension == "caf")
        let converted = try AVAudioFile(forReading: imported)
        let duration = Double(converted.length) / converted.processingFormat.sampleRate
        // AAC encoders pad with priming/remainder frames; allow slack.
        #expect(abs(duration - 2) < 0.2)
    }

    @Test("Sounds longer than the limit are rejected with the measured duration")
    func rejectsTooLong() throws {
        let source = try makeFixture(named: "Anthem.wav", duration: 6.2)
        #expect {
            try store.importSound(from: source)
        } throws: { error in
            guard case let CustomSoundStore.ImportError.tooLong(seconds) = error else { return false }
            return abs(seconds - 6.2) < 0.01
        }
        #expect(store.availableSounds().isEmpty)
    }

    @Test("Non-audio bytes are rejected as unreadable")
    func rejectsNonAudio() throws {
        let source = workDirectory.appendingPathComponent("fake.wav")
        try Data("not audio at all".utf8).write(to: source)
        #expect(throws: CustomSoundStore.ImportError.unreadableAudio) {
            try store.importSound(from: source)
        }
        #expect(store.availableSounds().isEmpty)
    }

    @Test("Re-importing the same name keeps both sounds under distinct names")
    func deduplicatesNames() throws {
        let source = try makeFixture(named: "Ding.wav", duration: 0.5)
        let first = try store.importSound(from: source)
        let second = try store.importSound(from: source)

        #expect(first != second)
        #expect(second.deletingPathExtension().lastPathComponent == "Ding 2")
        #expect(store.availableSounds().count == 2)
    }

    @Test("Deleting removes the converted file")
    func deleteRemovesFile() throws {
        let source = try makeFixture(named: "Ding.wav", duration: 0.5)
        let imported = try store.importSound(from: source)
        try store.deleteSound(at: imported)
        #expect(store.availableSounds().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: imported.path))
    }

    @Test("Prepared notification copy names are sanitized and prefixed")
    func preparedName() {
        let url = URL(fileURLWithPath: "/tmp/sounds/My Fancy Sound!.caf")
        #expect(
            CustomSoundStore.preparedNotificationSoundName(for: url) == "Codevisor-My-Fancy-Sound-.caf"
        )
    }
}
