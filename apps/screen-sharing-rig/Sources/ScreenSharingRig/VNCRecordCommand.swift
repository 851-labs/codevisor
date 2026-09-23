#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingTesting

  /// `screen-sharing-rig vnc-record`: captures a real server's bytes after the
  /// handshake into an `RFBRecording` fixture (851-2326), with the outcome of
  /// replaying it as the expectation the replay test checks. Point it at
  /// `bun run vnc:interop --keep` for TigerVNC.
  enum VNCRecordCommand {
    static let usage = """
      Usage: screen-sharing-rig vnc-record --host H --port P [--password P] [--seconds 3]
                                           [--pointer X,Y] [--quality 0-9] --source TEXT --out FILE.json
      Records what the client reads after authentication (no credentials are kept),
      for --seconds, optionally moving the pointer to X,Y first (TigerVNC then sends
      its cursor shape), and writes a fixture whose expected outcome is its replay.
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
      guard let host = values["host"], let port = values["port"].flatMap(UInt16.init), let out = values["out"],
        let source = values["source"]
      else { fail(usage) }
      let seconds = values["seconds"].flatMap(Double.init) ?? 3
      let pointer = values["pointer"]?.split(separator: ",").compactMap { UInt16($0) }
      let quality = values["quality"].flatMap(Int.init)
      Task {
        do {
          let recording = try await record(
            host: host, port: port, password: values["password"], seconds: seconds,
            pointer: pointer?.count == 2 ? (pointer![0], pointer![1]) : nil, quality: quality, source: source)
          try recording.write(to: URL(fileURLWithPath: out))
          print(
            "Recorded \(recording.byteCount) bytes in \(recording.server.count) chunks: "
              + "\(recording.expected?.updates ?? 0) updates, \(recording.expected?.events.count ?? 0) events → \(out)")
          exit(EXIT_SUCCESS)
        } catch {
          fail("vnc-record: \(error.localizedDescription)")
        }
      }
      dispatchMain()
    }

    static func record(
      host: String, port: UInt16, password: String?, seconds: Double, pointer: (UInt16, UInt16)?, quality: Int?,
      source: String
    ) async throws -> RFBRecording {
      let transport = RFBRecordingTransport(try await RFBNetworkTransport.connect(host: host, port: port))
      let client = try RFBClient(transport: transport, qualityLevel: quality)
      let outcome = try await client.connect(password: password)
      transport.start()  // after authentication: nothing credential-derived is recorded
      let run = Task { try await client.run(onUpdate: { _, _ in }, onEvent: { _ in }) }
      if let pointer {
        try await Task.sleep(for: .milliseconds(300))
        try await client.send(.pointerEvent(buttons: 0, x: pointer.0, y: pointer.1))
      }
      try await Task.sleep(for: .seconds(seconds))
      transport.stop()
      run.cancel()
      client.close()
      var recording = RFBRecording(
        source: source, width: outcome.parameters.width, height: outcome.parameters.height,
        server: transport.recorded)
      // With JPEG allowed the pixel hash isn't portable across OS versions: keep the rest.
      recording.expected = RFBRecording.comparable(try await recording.replay(), lossy: quality != nil)
      return recording
    }

    private static func fail(_ message: String) -> Never {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(2)
    }
  }
#endif
