import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Attachment preview sizing")
struct AttachmentPreviewSizingTests {
    @Test("The first resolved ratio remains authoritative")
    func geometryLocksItsFirstResolution() {
        var geometry = AttachmentPreviewGeometryState()

        geometry.resolve(aspectRatio: 3.0 / 4.0)
        geometry.resolve(aspectRatio: 16.0 / 9.0)

        #expect(geometry.isResolved)
        #expect(abs((geometry.aspectRatio ?? 0) - 3.0 / 4.0) < 0.001)
    }

    @Test("Invalid intrinsic geometry resolves to a stable fallback")
    func geometryUsesFallback() {
        var geometry = AttachmentPreviewGeometryState()

        geometry.resolve(aspectRatio: .infinity, fallbackAspectRatio: 8.5 / 11.0)

        #expect(geometry.isResolved)
        #expect(abs((geometry.aspectRatio ?? 0) - 8.5 / 11.0) < 0.001)
    }

    @Test("Landscape media uses the available width")
    func landscape() {
        let size = boundedAttachmentPreviewSize(
            aspectRatio: 16.0 / 9.0,
            maximumSize: CGSize(width: 320, height: 280)
        )

        #expect(size.width == 320)
        #expect(abs(size.height - 180) < 0.001)
    }

    @Test("Portrait and square media stay within the height bound")
    func portraitAndSquare() {
        let portrait = boundedAttachmentPreviewSize(
            aspectRatio: 9.0 / 16.0,
            maximumSize: CGSize(width: 320, height: 280)
        )
        let square = boundedAttachmentPreviewSize(
            aspectRatio: 1,
            maximumSize: CGSize(width: 320, height: 280)
        )

        #expect(abs(portrait.width - 157.5) < 0.001)
        #expect(portrait.height == 280)
        #expect(square == CGSize(width: 280, height: 280))
    }

    @Test("Missing or invalid dimensions use the fallback ratio")
    func fallback() {
        let missing = boundedAttachmentPreviewSize(
            aspectRatio: nil,
            maximumSize: CGSize(width: 320, height: 280)
        )
        let invalid = boundedAttachmentPreviewSize(
            aspectRatio: .infinity,
            maximumSize: CGSize(width: 320, height: 280),
            fallbackAspectRatio: 1
        )

        #expect(abs(missing.height - 180) < 0.001)
        #expect(invalid == CGSize(width: 280, height: 280))
    }
}
