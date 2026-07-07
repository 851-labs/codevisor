import SwiftUI
import AppKit
import PDFKit

/// A full-window attachment viewer: dark backdrop, centered image or PDF,
/// zoom controls (percentage with − / + in 25% steps), download, and close.
/// Presented from composer thumbnails and transcript attachments via
/// `LightboxController`.
struct AttachmentLightbox: View {
    let item: LightboxItem
    let controller: LightboxController

    @State private var image: NSImage?
    @State private var pdfDocument: PDFDocument?
    @State private var loadFailed = false
    /// 1.0 == fit-to-window; the label shows it as 100%.
    @State private var zoom: CGFloat = 1.0
    @FocusState private var isFocused: Bool

    private static let zoomStep: CGFloat = 0.25
    private static let zoomRange: ClosedRange<CGFloat> = 0.1...5.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture { controller.dismiss() }

            content

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        controlCircle(systemName: "square.and.arrow.down", help: "Download") { download() }
                        controlCircle(systemName: "xmark", help: "Close (⎋)") { controller.dismiss() }
                            // Escape as the standard cancel action; key
                            // equivalents win over the focused text view.
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(16)
                Spacer()
            }

            VStack {
                Spacer()
                zoomControls
                    .padding(.bottom, 20)
            }
        }
        .task(id: item) { await load() }
        .onExitCommand { controller.dismiss() }
        // Focusable so Escape (onExitCommand) reaches the overlay — and
        // actually focused on appear, otherwise first responder stays on the
        // composer text view and Escape never gets here.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .accessibilityLabel("Image viewer, \(item.name)")
    }

    @ViewBuilder
    private var content: some View {
        if let pdfDocument {
            LightboxPDFView(document: pdfDocument, zoom: zoom)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 64)
                .padding(.top, 64)
                .padding(.bottom, 76)
        } else if let image {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: fittedSize(image: image, in: proxy.size).width * zoom,
                            height: fittedSize(image: image, in: proxy.size).height * zoom
                        )
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height
                        )
                }
            }
            .padding(48)
        } else if loadFailed {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("This attachment is no longer available.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                setZoom(zoom - Self.zoomStep)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Zoom out")

            Text("\(Int((zoom * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 48)

            Button {
                setZoom(zoom + Self.zoomStep)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Zoom in")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func controlCircle(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    private func fittedSize(image: NSImage, in container: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0, container.width > 0, container.height > 0 else {
            return size
        }
        // Fit within the padded container; never upscale past natural size at 100%.
        let scale = min(container.width / size.width, container.height / size.height, 1)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func load() async {
        zoom = 1.0
        loadFailed = false
        image = nil
        pdfDocument = nil
        let data: Data?
        switch item {
        case let .local(localData, _):
            data = localData
        case let .remote(fileId, _):
            data = try? await controller.imageStore?.data(for: fileId)
        }
        guard let data else {
            loadFailed = true
            return
        }
        if isPDFData(data), let document = PDFDocument(data: data) {
            pdfDocument = document
            return
        }
        image = NSImage(data: data)
        loadFailed = image == nil
    }

    private func isPDFData(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual(Array("%PDF-".utf8))
    }

    private func download() {
        let item = item
        Task { @MainActor in
            let data: Data?
            switch item {
            case let .local(localData, _):
                data = localData
            case let .remote(fileId, _):
                data = try? await controller.imageStore?.data(for: fileId)
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }
}

/// PDFKit-backed document view for the lightbox: vertical continuous pages
/// with the shared zoom controls mapped onto PDFView's scale (1.0 == fit).
private struct LightboxPDFView: NSViewRepresentable {
    let document: PDFDocument
    let zoom: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var appliedZoom: CGFloat = 1.0
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
            context.coordinator.appliedZoom = 1.0
        }
        // Only touch the scale when OUR control changed, so PDFView's own
        // pinch/trackpad zoom isn't fought on unrelated SwiftUI updates.
        guard context.coordinator.appliedZoom != zoom else { return }
        context.coordinator.appliedZoom = zoom
        if zoom == 1.0 {
            view.autoScales = true
        } else {
            let fit = view.scaleFactorForSizeToFit
            if fit > 0 {
                view.scaleFactor = fit * zoom
            }
        }
    }
}
