#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingRigKit

  /// `screen-sharing-rig vnc-sample`: measures a real VNC server (851-2322),
  /// where `vnc-bench` measures the reference server. It connects the product's
  /// `RFBClient` (continuous updates, fences, Tight) and, while whatever runs on
  /// the desktop changes it, reports updates/s, Mbit/s and the round trip. With
  /// `--keys N` it then types N keys (alternately "x" and BackSpace, so a focused
  /// terminal's line stays clean) and times each from send to the next update
  /// that carries pixels: the keystroke-to-screen latency a user feels.
  enum VNCSampleCommand {
    static let usage = """
      Usage: screen-sharing-rig vnc-sample --host H --port P [--password P] [--seconds 10]
                                           [--keys 0] [--key-gap-ms 250] [--quality 0-9]
                                           [--desktop-size WxH]
      Prints one JSON line: updates/s, Mbit/s, bytes/update and round-trip p50 over --seconds,
      then echo latency p50/p95 (ms) over --keys keystrokes. Run the desktop's workload
      alongside (e.g. over ssh); keep the desktop otherwise still while typing.
      --desktop-size asks the server to resize the desktop first (as a viewer pane does) and
      holds it for the sample.
      """

    static func main(arguments: [String]) {
      if arguments.contains("--help") {
        print(usage)
        return
      }
      var values: [String: String] = [:]
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        guard argument.hasPrefix("--"), let value = iterator.next() else {
          fail("\(argument) needs a value\n\n\(usage)")
        }
        values[String(argument.dropFirst(2))] = value
      }
      guard let host = values["host"], let port = values["port"].flatMap(UInt16.init) else { fail(usage) }
      let options = Options(
        seconds: values["seconds"].flatMap(Double.init) ?? 10, keys: values["keys"].flatMap(Int.init) ?? 0,
        keyGap: .milliseconds(values["key-gap-ms"].flatMap(Int.init) ?? 250),
        quality: values["quality"].flatMap(Int.init),
        desktopSize: values["desktop-size"].map { $0.split(separator: "x").compactMap { Int($0) } })
      Task {
        do {
          let result = try await sample(host: host, port: port, password: values["password"], options: options)
          let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
          print(String(decoding: data, as: UTF8.self))
          exit(EXIT_SUCCESS)
        } catch {
          fail("vnc-sample: \(error.localizedDescription)")
        }
      }
      dispatchMain()
    }

    struct Options {
      var seconds: Double
      var keys: Int
      var keyGap: Duration
      var quality: Int?
      var desktopSize: [Int]?
    }

    static func sample(host: String, port: UInt16, password: String?, options: Options) async throws -> [String: Any] {
      let client = try RFBClient(
        transport: try await RFBNetworkTransport.connect(host: host, port: port), qualityLevel: options.quality)
      let outcome = try await client.connect(password: password)
      let log = SampleLog()
      let run = Task {
        try await client.run(
          onUpdate: { _, update in log.update(update) },
          onEvent: { if case .roundTrip(let duration) = $0 { log.roundTrip(duration) } })
      }
      defer {
        run.cancel()
        client.close()
      }
      // The first full frame isn't part of the steady state.
      await log.firstUpdate()
      if let size = options.desktopSize, size.count == 2 {
        try await client.send(
          .setDesktopSize(
            width: size[0], height: size[1], screens: [RFBScreen(id: 0, x: 0, y: 0, width: size[0], height: size[1])]))
      }
      log.reset()
      let started = ContinuousClock.now
      try await Task.sleep(for: .seconds(options.seconds))
      let elapsed = started.duration(to: .now)
      let passive = log.snapshot()
      var echoes: [Double] = []
      var missed = 0
      for index in 0..<options.keys {
        let keysym: UInt32 = index.isMultiple(of: 2) ? 0x78 : RFBKeysym.backSpace
        try await Task.sleep(for: options.keyGap)  // let the previous echo settle
        let sent = ContinuousClock.now
        let echo = log.armEcho(after: sent)
        try await client.send(.keyEvent(keysym: keysym, down: true))
        try await client.send(.keyEvent(keysym: keysym, down: false))
        if let latency = await echo.value(timeout: .seconds(2)) {
          echoes.append(latency / .milliseconds(1))
        } else {
          missed += 1
        }
      }
      let seconds = elapsed / .seconds(1)
      func rounded(_ value: Double?) -> Any { value.map { ($0 * 100).rounded() / 100 } ?? NSNull() }
      return [
        "server": outcome.parameters.name,
        "size": "\(outcome.parameters.width)x\(outcome.parameters.height)",
        "seconds": rounded(seconds),
        "updatesPerSecond": rounded(Double(passive.updates) / seconds),
        "mbitPerSecond": rounded(Double(passive.bytes) * 8 / seconds / 1_000_000),
        "bytesPerUpdate": passive.updates > 0 ? passive.bytes / passive.updates : 0,
        "roundTripP50Ms": rounded(VNCBenchStatistics.median(passive.roundTrips)),
        "echoP50Ms": rounded(VNCBenchStatistics.percentile(echoes, 0.5)),
        "echoP95Ms": rounded(VNCBenchStatistics.percentile(echoes, 0.95)),
        "echoes": echoes.count, "echoesMissed": missed,
      ]
    }

    private static func fail(_ message: String) -> Never {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(2)
    }
  }

  /// What the read loop saw, behind a lock (it runs on the client's actor).
  private final class SampleLog: @unchecked Sendable {
    struct Snapshot {
      var updates = 0
      var bytes = 0
      var roundTrips: [Double] = []
    }

    private let lock = NSLock()
    private var current = Snapshot()
    private var sawFirst = false
    private var firstWaiter: CheckedContinuation<Void, Never>?
    private var echo: Echo?

    func update(_ update: RFBUpdate) {
      let (first, armed): (CheckedContinuation<Void, Never>?, Echo?) = lock.withLock {
        current.updates += 1
        current.bytes += update.byteCount
        var first: CheckedContinuation<Void, Never>?
        if !sawFirst, !update.rectangles.isEmpty {
          sawFirst = true
          first = firstWaiter
          firstWaiter = nil
        }
        // Only an update with pixels can be the keystroke's echo.
        let armed = update.rectangles.isEmpty ? nil : echo
        if armed != nil { echo = nil }
        return (first, armed)
      }
      first?.resume()
      armed?.resolve(ContinuousClock.now)
    }

    func roundTrip(_ duration: Duration) {
      lock.withLock { current.roundTrips.append(duration / .milliseconds(1)) }
    }

    func firstUpdate() async {
      await withCheckedContinuation { continuation in
        let ready = lock.withLock {
          if sawFirst { return true }
          firstWaiter = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    }

    func reset() { lock.withLock { current = Snapshot() } }
    func snapshot() -> Snapshot { lock.withLock { current } }

    func armEcho(after sent: ContinuousClock.Instant) -> Echo {
      let echo = Echo(sent: sent)
      lock.withLock { self.echo = echo }
      return echo
    }
  }

  /// One keystroke's wait for its echo; resolves once, by an update or the timeout.
  private final class Echo: @unchecked Sendable {
    private let lock = NSLock()
    private let sent: ContinuousClock.Instant
    private var result: Duration??
    private var waiter: CheckedContinuation<Duration?, Never>?

    init(sent: ContinuousClock.Instant) { self.sent = sent }

    func resolve(_ at: ContinuousClock.Instant) { finish(sent.duration(to: at)) }

    func value(timeout: Duration) async -> Duration? {
      let timer = Task {
        try? await Task.sleep(for: timeout)
        finish(nil)
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { continuation in
        let done: Duration?? = lock.withLock {
          if let result { return result }
          waiter = continuation
          return nil
        }
        if let done { continuation.resume(returning: done) }
      }
    }

    private func finish(_ value: Duration?) {
      let waiter: CheckedContinuation<Duration?, Never>? = lock.withLock {
        guard result == nil else { return nil }
        result = .some(value)
        defer { self.waiter = nil }
        return self.waiter
      }
      waiter?.resume(returning: value)
    }
  }
#endif
