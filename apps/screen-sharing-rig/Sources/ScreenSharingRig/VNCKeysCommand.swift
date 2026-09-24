#if os(macOS)
  import Foundation
  import ScreenSharing

  /// `screen-sharing-rig vnc-keys`: sends Mac keyboard shortcuts to a VNC server
  /// exactly as the viewer does, through `VNCKeyTranslator` (851-2335): ⌘ becomes
  /// Control, letters go through a fixed US layout, so a check on a real desktop
  /// (Mousepad, xfce4-terminal) exercises the product's key mapping.
  enum VNCKeysCommand {
    static let usage = """
      Usage: screen-sharing-rig vnc-keys --host H --port P [--password P] [--gap-ms 150] CHORD...
      A chord is modifiers and one key joined by "+", e.g. cmd+a cmd+shift+c return.
      Modifiers: cmd, shift, ctrl, opt. Keys: a–z, return, tab, escape, home, end, up, down, left, right.
      """

    static func main(arguments: [String]) {
      if arguments.contains("--help") {
        print(usage)
        return
      }
      var values: [String: String] = [:]
      var chords: [String] = []
      var iterator = arguments.makeIterator()
      while let argument = iterator.next() {
        if argument.hasPrefix("--") {
          guard let value = iterator.next() else { fail("\(argument) needs a value\n\n\(usage)") }
          values[String(argument.dropFirst(2))] = value
        } else {
          chords.append(argument)
        }
      }
      guard let host = values["host"], let port = values["port"].flatMap(UInt16.init), !chords.isEmpty else {
        fail(usage)
      }
      let gap = Duration.milliseconds(values["gap-ms"].flatMap(Int.init) ?? 150)
      let messages: [[RFBClientMessage]]
      do { messages = try chords.map(Self.messages) } catch { fail("vnc-keys: \(error.localizedDescription)") }
      Task {
        do {
          let (client, _) = try await VNCConnection.open(host: host, port: port, password: values["password"])
          let run = Task { try await client.run(onUpdate: { _, _ in }, onEvent: { _ in }) }
          for (chord, keys) in zip(chords, messages) {
            for message in keys { try await client.send(message) }
            print("sent \(chord)")
            try await Task.sleep(for: gap)
          }
          run.cancel()
          client.close()
          exit(EXIT_SUCCESS)
        } catch {
          fail("vnc-keys: \(error.localizedDescription)")
        }
      }
      dispatchMain()
    }

    /// Mac virtual key codes and their `ScreenSharingInputEvent` modifier bits.
    static let modifiers: [String: (code: UInt16, bit: UInt8)] = [
      "shift": (56, 1), "ctrl": (59, 2), "opt": (58, 4), "cmd": (55, 8),
    ]
    static let keys: [String: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
      "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
      "m": 46, "return": 36, "tab": 48, "escape": 53, "home": 115, "end": 119, "left": 123, "right": 124,
      "down": 125, "up": 126,
    ]
    /// A US layout for the letters (what `VNCKeyTranslator` asks the Mac's layout).
    static let translator = VNCKeyTranslator { code, carbon in
      guard let name = keys.first(where: { $0.value == code })?.key, name.count == 1,
        let scalar = name.unicodeScalars.first
      else { return nil }
      let shifted = carbon & UInt32(1 << 1) != 0  // Carbon shiftKey >> 8
      return shifted ? String(scalar).uppercased().unicodeScalars.first : scalar
    }

    struct ChordError: LocalizedError {
      let errorDescription: String?
    }

    /// Modifier downs, the key down and up, modifier ups: what the viewer sends for one shortcut.
    static func messages(_ chord: String) throws -> [RFBClientMessage] {
      let parts = chord.lowercased().split(separator: "+").map(String.init)
      guard let keyName = parts.last, let code = keys[keyName] else {
        throw ChordError(errorDescription: "unknown key in \(chord)")
      }
      var mask: UInt8 = 0
      var downs: [RFBClientMessage] = []
      var ups: [RFBClientMessage] = []
      for name in parts.dropLast() {
        guard let modifier = modifiers[name] else { throw ChordError(errorDescription: "unknown modifier \(name)") }
        mask |= modifier.bit
        guard let keysym = translator.keysym(code: modifier.code, modifiers: mask) else { continue }
        downs.append(.keyEvent(keysym: keysym, down: true))
        ups.insert(.keyEvent(keysym: keysym, down: false), at: 0)
      }
      guard let keysym = translator.keysym(code: code, modifiers: mask) else {
        throw ChordError(errorDescription: "no keysym for \(chord)")
      }
      return downs + [.keyEvent(keysym: keysym, down: true), .keyEvent(keysym: keysym, down: false)] + ups
    }

    private static func fail(_ message: String) -> Never {
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(2)
    }
  }
#endif
