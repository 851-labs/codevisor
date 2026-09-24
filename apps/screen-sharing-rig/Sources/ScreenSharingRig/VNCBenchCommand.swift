#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingRigKit
  import ScreenSharingTesting

  /// `screen-sharing-rig vnc-bench`: the VNC benchmark of
  /// docs/plans/vnc-validation.md. For every scene × network profile it runs
  /// the reference server's scene in a separate `vnc-server` process (so this
  /// process's CPU is the client's), connects the product's `RFBClient` and
  /// frame publisher through `RFBShapedTransport`, and measures N runs. The
  /// pure statistics, report and baseline comparison live in
  /// `ScreenSharingRigKit` (`VNCBench*`).
  enum VNCBenchCommand {
    static let usage = """
      Usage: screen-sharing-rig vnc-bench [--scenes typing,scroll,photo,input] [--profiles lan,wan150]
                                          [--runs 3] [--frames 40] [--size 1280x800] [--seed 1] [--pace 60]
                                          [--quality 0-9]
                                          [--out DIR] [--baseline FILE] [--build HASH]
      Scenes: \(VNCBenchOptions.sceneNames.joined(separator: ", ")) ("input" measures pointer echo latency).
      Profiles: \(VNCBenchOptions.profileNames.joined(separator: ", ")).
      --pace: scene frames per second, like a real app (default 60); 0 plays a frame per request
      (the server then offers no continuous updates, so the client keeps requesting).
      --out writes bench.json and bench.md; --baseline compares and exits 1 on a regression
      beyond the noise band. Prefer `bun run vnc:bench`, which builds in release mode.
      """

    static func main(arguments: [String]) {
      if arguments.contains("--help") {
        print(usage)
        return
      }
      setvbuf(stdout, nil, _IOLBF, 0)
      let options: VNCBenchOptions
      do { options = try VNCBenchOptions(arguments: arguments) } catch {
        FileHandle.standardError.write(Data("vnc-bench: \(error.localizedDescription)\n\n\(usage)\n".utf8))
        exit(2)
      }
      Task {
        do { exit(try await run(options)) } catch {
          // Always leave the reason behind (851-2337): a one-off failure must be diagnosable afterwards.
          let record = failureRecord(error, serverOutput: ServerOutput.latest.tail)
          FileHandle.standardError.write(Data("vnc-bench: \(record)\n".utf8))
          if let output = options.output {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(record.utf8).write(to: directory.appendingPathComponent("bench-error.txt"))
          }
          exit(EXIT_FAILURE)
        }
      }
      dispatchMain()
    }

    /// The error, and what the last vnc-server printed (a crash or refusal shows up there).
    static func failureRecord(_ error: any Error, serverOutput: [String]) -> String {
      var lines = [error.localizedDescription]
      if !serverOutput.isEmpty { lines += ["", "vnc-server's last output:"] + serverOutput.map { "  \($0)" } }
      return lines.joined(separator: "\n")
    }

    static func run(_ options: VNCBenchOptions) async throws -> Int32 {
      var cases: [VNCBenchCase] = []
      for scene in options.scenes {
        for name in options.profiles {
          guard let profile = RFBNetworkProfile.named(name) else { throw VNCBenchError("unknown profile \(name)") }
          var runs: [[VNCBenchMetric: Double]] = []
          for index in 0..<options.runs {
            let label = "\(scene)/\(name) run \(index + 1)"
            let measured: [VNCBenchMetric: Double]
            do {
              measured = try await withWatchdog(label) {
                try await measure(scene: scene, profile: profile, options: options)
              }
            } catch let error as VNCBenchError where error.localizedDescription.hasPrefix(label) {
              throw error
            } catch {
              throw VNCBenchError("\(label): \(error.localizedDescription)")
            }
            print("  \(scene)/\(name) run \(index + 1)/\(options.runs): \(summary(measured))")
            runs.append(measured)
          }
          cases.append(VNCBenchCase(scene: scene, profile: name, runs: runs))
        }
      }
      let report = VNCBenchReport(machine: machine(), build: options.build, cases: cases)
      print("\n" + report.markdown())
      if let output = options.output {
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try report.json().write(to: directory.appendingPathComponent("bench.json"))
        try Data(report.markdown().utf8).write(to: directory.appendingPathComponent("bench.md"))
      }
      guard let path = options.baseline else { return 0 }
      let baseline = try JSONDecoder().decode(VNCBenchReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      let comparison = VNCBenchComparison(baseline: baseline, current: report)
      let text = "## Against \(path) (build `\(baseline.build)`)\n\n" + comparison.markdown()
      print(text)
      if let output = options.output {
        try Data(text.utf8).write(
          to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("comparison.md"))
      }
      print(
        comparison.regressions.isEmpty
          ? "vnc-bench: no regression beyond the noise band"
          : "vnc-bench: \(comparison.regressions.count) regression(s) beyond the noise band")
      return comparison.regressions.isEmpty ? 0 : 1
    }

    /// A run that stalls fails instead of hanging the benchmark (and `vnc:validate`) forever.
    private static func withWatchdog<T: Sendable>(
      _ name: String, limit: Duration = .seconds(180), _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
      try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
          try await Task.sleep(for: limit)
          throw VNCBenchError(
            "\(name) took longer than \(limit); stopping. If no update arrived at all, the scene may be waiting "
              + "for requests the client isn't sending (see 851-2336), or the server never started.")
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    }

    // MARK: One run

    private static func measure(
      scene: String, profile: RFBNetworkProfile, options: VNCBenchOptions
    ) async throws -> [VNCBenchMetric: Double] {
      let input = scene == "input"
      let server = try await ServerProcess.start(
        scene: input ? "idle" : scene, echo: input, seed: options.seed, pace: options.pace, width: options.width,
        height: options.height)
      defer { server.stop() }  // `stop` doesn't wait: the next run's server takes a fresh port anyway
      let transport = RFBShapedTransport(
        try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port), profile: profile,
        clock: ContinuousClock())
      let client = try RFBClient(transport: transport, qualityLevel: options.quality)
      _ = try await client.connect(password: nil)
      let metrics = ScreenSharingMetrics()
      let mailbox = ScreenSharingFrameMailbox()
      let publisher = VNCFramePublisher()
      let probe = EchoProbe()
      let (updates, continuation) = AsyncStream<Observed>.makeStream()
      let run = Task {
        do {
          try await client.run(
            onUpdate: { framebuffer, update in
              publisher.publish(
                framebuffer, changed: update.resized ? nil : update.rectangles, to: mailbox, metrics: metrics)
              continuation.yield(
                Observed(
                  latencyMs: update.latency?.milliseconds, bytes: update.byteCount,
                  linkBytes: update.linkBytes, linkSeconds: update.linkDuration.seconds,
                  echoed: probe.check(framebuffer)))
            }, onEvent: { _ in })
        } catch {
          continuation.finish()
        }
      }
      defer {
        run.cancel()
        client.close()
      }
      var iterator = updates.makeAsyncIterator()
      guard await iterator.next() != nil else { throw VNCBenchError("no first update from the \(scene) server") }
      return input
        ? try await measureInput(client: client, probe: probe, updates: &iterator, options: options)
        : try await measureThroughput(updates: &iterator, metrics: metrics, frames: options.frames)
    }

    private static func measureThroughput(
      updates: inout AsyncStream<Observed>.Iterator, metrics: ScreenSharingMetrics, frames: Int
    ) async throws -> [VNCBenchMetric: Double] {
      let started = ContinuousClock.now
      let cpu = cpuSeconds()
      let copied = metrics.snapshot().counters["vncBytesCopied", default: 0]
      var observed: [Observed] = []
      while observed.count < frames {
        guard let next = await updates.next() else { throw VNCBenchError("the server ended the stream early") }
        observed.append(next)
      }
      let seconds = started.duration(to: .now).seconds
      let cpuMs = (cpuSeconds() - cpu) * 1000
      let bytes = observed.map(\.bytes).reduce(0, +)
      let latencies = observed.compactMap(\.latencyMs)
      var measured: [VNCBenchMetric: Double] = [
        .updatesPerSecond: Double(frames) / seconds,
        .bytesPerUpdate: Double(bytes) / Double(frames),
        .megabitsPerSecond: Double(bytes) * 8 / seconds / 1_000_000,
        .cpuMsPerUpdate: cpuMs / Double(frames),
        .bytesCopiedPerUpdate: Double(metrics.snapshot().counters["vncBytesCopied", default: 0] - copied)
          / Double(frames),
      ]
      let linkSeconds = observed.map(\.linkSeconds).reduce(0, +)
      if linkSeconds > 0 {
        measured[.linkEstimateMbps] = Double(observed.map(\.linkBytes).reduce(0, +)) * 8 / linkSeconds / 1_000_000
      }
      // Request → applied only exists for requested updates; pushed ones (851-2312) have none.
      if latencies.count * 2 >= frames {
        measured[.updateLatencyP50Ms] = VNCBenchStatistics.median(latencies)
        measured[.updateLatencyP95Ms] = VNCBenchStatistics.percentile(latencies, 0.95)
      }
      return measured
    }

    /// Pointer events one at a time; each is timed until its echo marker is on the client's framebuffer.
    private static func measureInput(
      client: RFBClient, probe: EchoProbe, updates: inout AsyncStream<Observed>.Iterator, options: VNCBenchOptions
    ) async throws -> [VNCBenchMetric: Double] {
      var latencies: [Double] = []
      let marker = RFBLoopbackServer.echoMarkerSize
      for sequence in 1...options.frames {
        let x = (sequence * 97) % max(1, options.width - marker)
        let y = (sequence * 61) % max(1, options.height - marker)
        probe.expect(sequence: sequence, x: x, y: y)
        let sent = ContinuousClock.now
        try await client.send(.pointerEvent(buttons: 0, x: UInt16(x), y: UInt16(y)))
        while true {
          guard let next = await updates.next() else { throw VNCBenchError("the server ended the stream early") }
          if next.echoed == sequence { break }
        }
        latencies.append(sent.duration(to: .now).milliseconds)
      }
      return [
        .inputLatencyP50Ms: VNCBenchStatistics.median(latencies) ?? 0,
        .inputLatencyP95Ms: VNCBenchStatistics.percentile(latencies, 0.95) ?? 0,
      ]
    }

    private struct Observed: Sendable {
      /// Request → applied; nil for a pushed update (continuous updates).
      let latencyMs: Double?
      let bytes: Int
      /// What arrived while the client waited for the network, and that wait (851-2331).
      let linkBytes: Int
      let linkSeconds: Double
      /// The echo sequence found at the expected marker position, if any.
      let echoed: Int?
    }

    /// Where the next echo marker should appear; read by the update callback.
    private final class EchoProbe: @unchecked Sendable {
      private let lock = NSLock()
      private var expected: (sequence: Int, x: Int, y: Int)?
      func expect(sequence: Int, x: Int, y: Int) { lock.withLock { expected = (sequence, x, y) } }
      func check(_ framebuffer: RFBFramebuffer) -> Int? {
        guard let expected = lock.withLock({ expected }) else { return nil }
        guard expected.x < framebuffer.width, expected.y < framebuffer.height else { return nil }
        let pixel = framebuffer.pixel(x: expected.x, y: expected.y)
        return RFBLoopbackServer.echoSequence(blue: pixel.blue, green: pixel.green, red: pixel.red)
      }
    }

    // MARK: The scene server

    /// `screen-sharing-rig vnc-server --scene …` in its own process, on a free port.
    private final class ServerProcess: @unchecked Sendable {
      let process: Process
      let port: UInt16
      /// Finishes when the process has exited, from its termination handler.
      let exited: Task<Void, Never>

      private init(process: Process, port: UInt16, exited: Task<Void, Never>) {
        self.process = process
        self.port = port
        self.exited = exited
      }

      static func start(
        scene: String, echo: Bool, seed: UInt64, pace: Int, width: Int, height: Int
      ) async throws -> ServerProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = VNCBenchServer.arguments(
          scene: scene, echo: echo, seed: seed, pace: pace, width: width, height: height)
        let output = Pipe()
        process.standardOutput = output
        // Its errors still reach this process's stderr, and the last lines are kept for bench-error.txt.
        let errors = Pipe()
        process.standardError = errors
        let log = ServerOutput.begin()
        errors.fileHandleForReading.readabilityHandler = { handle in
          let data = handle.availableData
          guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return
          }
          FileHandle.standardError.write(data)
          log.append(data)
        }
        // Never `waitUntilExit` from a concurrency thread: it waits on a run loop those threads don't
        // service and can hang after the process is gone (seen in 851-2328's first validation).
        let (termination, finished) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in finished.finish() }
        let exited = Task { for await _ in termination {} }
        try process.run()
        let lines = output.fileHandleForReading.bytes.lines
        let ready = Task { () -> UInt16? in
          for try await line in lines {
            if let range = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression),
              let port = UInt16(line[range].split(separator: ":").last ?? "")
            {
              return port
            }
          }
          return nil
        }
        let deadline = Task {
          try await Task.sleep(for: .seconds(10))
          ready.cancel()
        }
        defer { deadline.cancel() }
        guard let port = try? await ready.value else {
          process.terminate()
          throw VNCBenchError("the vnc-server for \(scene) didn't report a port within 10 s")
        }
        return ServerProcess(process: process, port: port, exited: exited)
      }

      /// Asks the server to exit. Callers that need it gone await `exited`.
      func stop() {
        if process.isRunning { process.terminate() }
      }
    }

    /// The current vnc-server's stderr, last lines only.
    final class ServerOutput: @unchecked Sendable {
      private static let lock = NSLock()
      nonisolated(unsafe) private static var current = ServerOutput()
      static var latest: ServerOutput { lock.withLock { current } }
      static func begin() -> ServerOutput {
        let log = ServerOutput()
        lock.withLock { current = log }
        return log
      }

      private let lock = NSLock()
      private var lines: [String] = []
      private var partial = ""
      static let keep = 20

      func append(_ data: Data) {
        lock.withLock {
          let text = partial + String(decoding: data, as: UTF8.self)
          var split = text.components(separatedBy: "\n")
          partial = split.removeLast()
          lines = Array((lines + split.filter { !$0.isEmpty }).suffix(Self.keep))
        }
      }

      var tail: [String] { lock.withLock { lines + (partial.isEmpty ? [] : [partial]) } }
    }

    // MARK: Environment

    private static func cpuSeconds() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
      return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func machine() -> VNCBenchReport.Machine {
      var size = 0
      sysctlbyname("hw.model", nil, &size, nil, 0)
      var model = [CChar](repeating: 0, count: max(size, 1))
      sysctlbyname("hw.model", &model, &size, nil, 0)
      let version = ProcessInfo.processInfo.operatingSystemVersion
      let power = Process()
      power.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      power.arguments = ["-g", "batt"]
      let pipe = Pipe()
      power.standardOutput = pipe
      try? power.run()
      power.waitUntilExit()
      let battery = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      var loads = [Double](repeating: 0, count: 3)
      getloadavg(&loads, 3)
      return VNCBenchReport.Machine(
        model: String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        system: "\(version.majorVersion).\(version.minorVersion)",
        power: battery.contains("AC Power") ? "AC" : battery.contains("Battery Power") ? "battery" : "unknown",
        load: loads[0])
    }

    private static func summary(_ metrics: [VNCBenchMetric: Double]) -> String {
      metrics.sorted { $0.key < $1.key }.map { "\($0.key.label) \(String(format: "%.2f", $0.value))" }
        .joined(separator: ", ")
    }
  }

  extension Duration {
    fileprivate var seconds: Double {
      let (seconds, attoseconds) = components
      return Double(seconds) + Double(attoseconds) / 1e18
    }
    fileprivate var milliseconds: Double { seconds * 1000 }
  }
#endif
