enum ChromiumDeadline {
  static func run(within limit: Duration, _ work: @escaping () async -> Void) async {
    let (finished, signal) = AsyncStream<Void>.makeStream()
    let worker = Task {
      await work()
      signal.yield()
    }
    let timer = Task {
      try? await Task.sleep(for: limit)
      signal.yield()
    }
    for await _ in finished { break }
    timer.cancel()
    _ = worker
  }
}
