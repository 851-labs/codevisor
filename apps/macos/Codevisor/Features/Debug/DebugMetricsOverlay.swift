import AppKit
import Darwin
import Observation
import QuartzCore
import SwiftUI

/// Live diagnostics for one app window. Sampling is completely dormant while
/// the overlay is hidden so the debug tool does not become a permanent cost.
@MainActor
@Observable
final class DebugMetricsModel {
    private static let frameHistoryLimit = 90
    private static let resourceSampleInterval: Duration = .milliseconds(500)

    private(set) var isVisible = false
    private(set) var framesPerSecond = 0.0
    private(set) var frameDurationMilliseconds = 0.0
    private(set) var frameDurations: [Double] = []
    private(set) var cpuPercent = 0.0
    private(set) var memoryBytes: UInt64 = 0

    private var frameTimestamps: [TimeInterval] = []
    private var resourceTask: Task<Void, Never>?
    private var previousResourceSample: ProcessResourceSample?

    var memoryFraction: Double {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        guard physicalMemory > 0 else { return 0 }
        return Double(memoryBytes) / Double(physicalMemory)
    }

    func toggle() {
        isVisible.toggle()
        if isVisible {
            resetFrameMetrics()
            startResourceSampling()
        } else {
            resourceTask?.cancel()
            resourceTask = nil
            previousResourceSample = nil
        }
    }

    func recordFrame(at timestamp: TimeInterval) {
        guard isVisible else { return }

        if let previousTimestamp = frameTimestamps.last {
            let duration = timestamp - previousTimestamp
            // Ignore clock discontinuities while still retaining real stalls.
            if duration > 0, duration < 2 {
                frameDurations.append(duration * 1_000)
                if frameDurations.count > Self.frameHistoryLimit {
                    frameDurations.removeFirst(frameDurations.count - Self.frameHistoryLimit)
                }

                let smoothingWindow = frameDurations.suffix(12)
                frameDurationMilliseconds = smoothingWindow.reduce(0, +) / Double(smoothingWindow.count)
            }
        }

        frameTimestamps.append(timestamp)
        let cutoff = timestamp - 1
        frameTimestamps.removeAll { $0 < cutoff }
        if let first = frameTimestamps.first, frameTimestamps.count > 1 {
            let elapsed = timestamp - first
            if elapsed > 0 {
                framesPerSecond = Double(frameTimestamps.count - 1) / elapsed
            }
        }
    }

    private func resetFrameMetrics() {
        framesPerSecond = 0
        frameDurationMilliseconds = 0
        frameDurations.removeAll(keepingCapacity: true)
        frameTimestamps.removeAll(keepingCapacity: true)
    }

    private func startResourceSampling() {
        resourceTask?.cancel()
        previousResourceSample = nil
        sampleResources()
        resourceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.resourceSampleInterval)
                guard !Task.isCancelled else { return }
                self?.sampleResources()
            }
        }
    }

    private func sampleResources() {
        guard let sample = ProcessResourceSample.current() else { return }
        memoryBytes = sample.residentMemory

        if let previousResourceSample {
            let elapsed = sample.timestamp - previousResourceSample.timestamp
            let cpuNanoseconds = sample.cpuNanoseconds - previousResourceSample.cpuNanoseconds
            if elapsed > 0 {
                // Like Activity Monitor, 100% represents one fully occupied CPU core.
                cpuPercent = Double(cpuNanoseconds) / 1_000_000_000 / elapsed * 100
            }
        }
        previousResourceSample = sample
    }
}

private struct ProcessResourceSample {
    let timestamp: TimeInterval
    let cpuNanoseconds: UInt64
    let residentMemory: UInt64

    static func current() -> ProcessResourceSample? {
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, pointer, expectedSize)
        }
        guard result == expectedSize else { return nil }
        return ProcessResourceSample(
            timestamp: ProcessInfo.processInfo.systemUptime,
            cpuNanoseconds: info.pti_total_user + info.pti_total_system,
            residentMemory: info.pti_resident_size
        )
    }
}

/// Attaches the window-scoped HUD and publishes its toggle to the focused
/// scene, allowing the menu command to reach the correct window.
struct DebugMetricsOverlayModifier: ViewModifier {
    @State private var model = DebugMetricsModel()
    private let actionID = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomLeading) {
                if model.isVisible {
                    DebugMetricsOverlay(model: model)
                        .padding(12)
                }
            }
            .focusedSceneValue(
                \.debugOverlayToggle,
                DebugOverlayToggleAction(id: actionID) { model.toggle() }
            )
    }
}

private struct DebugMetricsOverlay: View {
    let model: DebugMetricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Performance", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("⌘` to hide")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
            }

            HStack(spacing: 8) {
                PrimaryMetric(
                    title: "FPS",
                    value: model.framesPerSecond.formatted(.number.precision(.fractionLength(1))),
                    tint: frameTint
                )
                PrimaryMetric(
                    title: "FRAME TIME",
                    value: "\(model.frameDurationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms",
                    tint: frameTint
                )
            }

            FrameDurationMeter(samples: model.frameDurations)
                .frame(height: 52)

            Divider()
                .overlay(.white.opacity(0.12))

            ResourceMetric(
                title: "CPU",
                value: "\(model.cpuPercent.formatted(.number.precision(.fractionLength(1))))%",
                fraction: model.cpuPercent / 100,
                tint: .cyan
            )
            ResourceMetric(
                title: "MEMORY",
                value: ByteCountFormatter.string(fromByteCount: Int64(model.memoryBytes), countStyle: .memory),
                fraction: model.memoryFraction,
                tint: .purple
            )
        }
        .padding(12)
        .frame(width: 286)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .overlay { DisplayFrameProbe(model: model).frame(width: 1, height: 1) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frameTint: Color {
        switch model.frameDurationMilliseconds {
        case ..<18: .green
        case ..<34: .yellow
        default: .orange
        }
    }
}

private struct PrimaryMetric: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResourceMetric: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .contentTransition(.numericText())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct FrameDurationMeter: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            let visibleSamples = Array(samples.suffix(60))
            let maximumSample = min(max(visibleSamples.max() ?? 16.67, 33.33), 100)

            var threshold = Path()
            let thresholdY = size.height - size.height * 16.67 / maximumSample
            threshold.move(to: CGPoint(x: 0, y: thresholdY))
            threshold.addLine(to: CGPoint(x: size.width, y: thresholdY))
            context.stroke(threshold, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard !visibleSamples.isEmpty else { return }
            let spacing = 1.5
            let barWidth = max((size.width - spacing * CGFloat(visibleSamples.count - 1)) / CGFloat(visibleSamples.count), 1)

            for (index, sample) in visibleSamples.enumerated() {
                let cappedSample = min(sample, maximumSample)
                let height = max(size.height * cappedSample / maximumSample, 1)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let color: Color = switch sample {
                case ..<18: .green
                case ..<34: .yellow
                default: .orange
                }
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.9)))
            }
        }
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

private struct DisplayFrameProbe: NSViewRepresentable {
    let model: DebugMetricsModel

    func makeNSView(context: Context) -> DisplayFrameProbeView {
        DisplayFrameProbeView(model: model)
    }

    func updateNSView(_ view: DisplayFrameProbeView, context: Context) {
        view.model = model
    }
}

private final class DisplayFrameProbeView: NSView {
    weak var model: DebugMetricsModel?
    private var frameDisplayLink: CADisplayLink?

    init(model: DebugMetricsModel) {
        self.model = model
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameDisplayLink?.invalidate()
        frameDisplayLink = nil

        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        link.add(to: .main, forMode: .common)
        frameDisplayLink = link
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        model?.recordFrame(at: displayLink.timestamp)
    }
}

struct DebugOverlayToggleAction: Equatable {
    let id: UUID
    let toggle: @MainActor () -> Void

    static func == (lhs: DebugOverlayToggleAction, rhs: DebugOverlayToggleAction) -> Bool {
        lhs.id == rhs.id
    }
}

private struct DebugOverlayToggleKey: FocusedValueKey {
    typealias Value = DebugOverlayToggleAction
}

extension FocusedValues {
    var debugOverlayToggle: DebugOverlayToggleAction? {
        get { self[DebugOverlayToggleKey.self] }
        set { self[DebugOverlayToggleKey.self] = newValue }
    }
}

struct DebugOverlayCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            DebugOverlayMenuItem()
        }
    }
}

private struct DebugOverlayMenuItem: View {
    @FocusedValue(\.debugOverlayToggle) private var action

    var body: some View {
        Button("Toggle Debug Overlay") { action?.toggle() }
            .keyboardShortcut("`", modifiers: .command)
            .disabled(action == nil)
    }
}
