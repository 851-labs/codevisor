import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class DebugMetricsModel {
  private static let frameHistoryLimit = 90
  private static let framePresentationInterval: TimeInterval = 0.25
  private static let resourceSampleInterval: Duration = .milliseconds(500)

  private(set) var isVisible = false
  private(set) var framesPerSecond = 0.0
  private(set) var frameDurationMilliseconds = 0.0
  private(set) var frameDurations: [Double] = []
  private(set) var cpuPercent = 0.0
  private(set) var memoryBytes: UInt64 = 0
  private(set) var targetFrameDurationMilliseconds = 1_000.0 / 60.0

  @ObservationIgnored private var sampledFrameDurations: [Double] = []
  @ObservationIgnored private var sampledFrameTimestamps: [TimeInterval] = []
  @ObservationIgnored private var lastFramePresentationTimestamp: TimeInterval = 0
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

    recordFrameDuration(at: timestamp)

    sampledFrameTimestamps.append(timestamp)
    let cutoff = timestamp - 1
    sampledFrameTimestamps.removeAll { $0 < cutoff }

    guard timestamp - lastFramePresentationTimestamp >= Self.framePresentationInterval else {
      return
    }
    publishFrameMetrics(at: timestamp)
  }

  private func recordFrameDuration(at timestamp: TimeInterval) {
    if let previousTimestamp = sampledFrameTimestamps.last {
      let duration = timestamp - previousTimestamp
      if duration > 0, duration < 2 {
        sampledFrameDurations.append(duration * 1_000)
        if sampledFrameDurations.count > Self.frameHistoryLimit {
          sampledFrameDurations.removeFirst(
            sampledFrameDurations.count - Self.frameHistoryLimit
          )
        }
      }
    }
  }

  private func publishFrameMetrics(at timestamp: TimeInterval) {
    lastFramePresentationTimestamp = timestamp
    frameDurations = sampledFrameDurations
    let smoothingWindow = sampledFrameDurations.suffix(12)
    if !smoothingWindow.isEmpty {
      frameDurationMilliseconds = smoothingWindow.reduce(0, +) / Double(smoothingWindow.count)
    }
    if let first = sampledFrameTimestamps.first, sampledFrameTimestamps.count > 1 {
      let elapsed = timestamp - first
      if elapsed > 0 {
        framesPerSecond = Double(sampledFrameTimestamps.count - 1) / elapsed
      }
    }
  }

  func configureDisplay(for window: NSWindow) {
    let maximumFramesPerSecond = max(1, window.screen?.maximumFramesPerSecond ?? 60)
    targetFrameDurationMilliseconds = 1_000 / Double(maximumFramesPerSecond)
  }

  private func resetFrameMetrics() {
    framesPerSecond = 0
    frameDurationMilliseconds = 0
    frameDurations.removeAll(keepingCapacity: true)
    sampledFrameDurations.removeAll(keepingCapacity: true)
    sampledFrameTimestamps.removeAll(keepingCapacity: true)
    lastFramePresentationTimestamp = 0
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
