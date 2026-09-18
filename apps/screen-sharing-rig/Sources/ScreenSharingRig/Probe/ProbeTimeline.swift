import ScreenSharing
import Darwin
import Foundation

/// At most 361 samples (the CLI bounds duration / interval to 360, plus the
/// final sample); each sample copies counters, labels and bounded timing
/// summaries, not raw histories. CPU is whole-process user+system time (100%
/// is one core); GPU utilization is not measured here.
@MainActor
struct ProbeTimeline {
  struct Sample: Encodable {
    let elapsedSeconds: Double
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
    let cpuPercentOfOneCore: Double?
    let presentedFramesPerSecond: Double?
    let sender: ScreenSharingMetrics.Snapshot
    let receiver: ScreenSharingMetrics.Snapshot
    let rendererMailboxDrops: Int
  }
  private(set) var samples: [Sample] = []
  private var previous: (time: Double, cpu: Double, frames: Int)?

  mutating func append(
    elapsed: Double, sender: ScreenSharingMetrics.Snapshot, receiver: ScreenSharingMetrics.Snapshot, drops: Int
  ) {
    var memory = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    var usage = rusage()
    let cpuStatus = getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    let frames = receiver.counters["presentedFrames", default: 0]
    let interval = previous.map { elapsed - $0.time } ?? 0
    samples.append(
      Sample(
        elapsedSeconds: elapsed,
        residentBytes: memoryStatus == KERN_SUCCESS ? memory.resident_size : nil,
        physicalFootprintBytes: memoryStatus == KERN_SUCCESS ? memory.phys_footprint : nil,
        cpuPercentOfOneCore: cpuStatus == 0 && interval > 0 ? (cpu - (previous?.cpu ?? cpu)) / interval * 100 : nil,
        presentedFramesPerSecond: interval > 0 ? Double(frames - (previous?.frames ?? frames)) / interval : nil,
        sender: sender, receiver: receiver, rendererMailboxDrops: drops))
    previous = cpuStatus == 0 ? (elapsed, cpu, frames) : nil
  }
  func writeProgress(to report: URL?) throws {
    guard let report else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(samples).write(to: URL(fileURLWithPath: report.path + ".progress.json"), options: .atomic)
  }
}
