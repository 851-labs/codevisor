import CodevisorCore
import Testing
@testable import CodevisorUI

@MainActor
@Suite("Streaming assistant response entrance sequence")
struct StreamingAssistantResponseEntranceSequenceTests {
    private let firstFile = PreviewFile(
        source: .attachment(fileId: "file-1"),
        name: "plot.png",
        mimeType: "image/png",
        kind: .image
    )
    private let secondFile = PreviewFile(
        source: .serverPath("./report.pdf"),
        name: "report.pdf",
        mimeType: "application/pdf",
        kind: .file
    )

    @Test("Files reveal between Markdown slices in document order")
    func documentOrder() {
        let sequence = StreamingAssistantResponseEntranceSequence()
        let segments: [AssistantMarkdownSegment] = [
            .markdown("Before"),
            .file(firstFile, label: "Plot"),
            .markdown("Between"),
            .file(secondFile, label: "Report"),
            .markdown("After"),
        ]

        var resolution = sequence.resolve(
            segments: segments,
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 1)
        let firstID = try! #require(resolution.pendingFileID)

        #expect(sequence.beginReveal(fileID: firstID) == .started)
        resolution = sequence.resolve(
            segments: segments,
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 2)
        #expect(resolution.revealingSegmentIndex == 1)

        #expect(sequence.finishReveal(fileID: firstID))
        resolution = sequence.resolve(
            segments: segments,
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 3)
        let secondID = try! #require(resolution.pendingFileID)
        #expect(secondID != firstID)

        #expect(sequence.beginReveal(fileID: secondID) == .started)
        #expect(sequence.finishReveal(fileID: secondID))
        resolution = sequence.resolve(
            segments: segments,
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == segments.count)
        #expect(resolution.pendingFileID == nil)
    }

    @Test("Navigation, completion, and Reduce Motion expose files immediately")
    func immediatePresentation() {
        let segments: [AssistantMarkdownSegment] = [
            .markdown("Before"),
            .file(firstFile, label: "Plot"),
        ]

        for inputs in [
            (animationEnabled: true, animatesInitialContent: false, reduceMotion: false),
            (animationEnabled: false, animatesInitialContent: true, reduceMotion: false),
            (animationEnabled: true, animatesInitialContent: true, reduceMotion: true),
        ] {
            let sequence = StreamingAssistantResponseEntranceSequence()
            let resolution = sequence.resolve(
                segments: segments,
                responseStreamID: "turn:main:answer",
                animationEnabled: inputs.animationEnabled,
                animatesInitialContent: inputs.animatesInitialContent,
                reduceMotion: inputs.reduceMotion
            )
            #expect(resolution.visibleSegmentCount == segments.count)
            #expect(resolution.pendingFileID == nil)
        }
    }

    @Test("Preview loading changes do not replay an entrance")
    func stableFileIdentity() {
        let sequence = StreamingAssistantResponseEntranceSequence()
        var resolution = sequence.resolve(
            segments: [.file(firstFile, label: "Plot")],
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        let fileID = try! #require(resolution.pendingFileID)
        #expect(sequence.beginReveal(fileID: fileID) == .started)
        #expect(sequence.beginReveal(fileID: fileID) == .resumed)
        #expect(sequence.finishReveal(fileID: fileID))

        let renamed = PreviewFile(
            source: firstFile.source,
            name: "loaded-plot.png",
            mimeType: firstFile.mimeType,
            kind: firstFile.kind
        )
        resolution = sequence.resolve(
            segments: [.file(renamed, label: "Loaded plot")],
            responseStreamID: "turn:main:answer",
            animationEnabled: true,
            animatesInitialContent: true,
            reduceMotion: false
        )
        #expect(resolution.visibleSegmentCount == 1)
        #expect(resolution.pendingFileID == nil)
    }
}
