#if os(macOS)
  import Foundation
  import ScreenSharing
  import ScreenSharingTesting

  /// `screen-sharing-rig vnc-server`: a VNC server on 127.0.0.1 with an
  /// animated desktop, logging the input it receives. The tophat target for
  /// the app's VNC viewer when no other server is at hand.
  enum VNCServerCommand {
    static let usage = """
      Usage: screen-sharing-rig vnc-server [--port 5901] [--password secret | --no-password]
                                          [--size 1280x800] [--fps 10] [--encoding zrle|raw]
                                          [--scene KIND [--seed N] [--scene-fps N]] [--echo]
                                          [--requested-only]
      Serves an animated desktop over RFB 3.8 on 127.0.0.1 and prints the keys, buttons and
      clipboard text the viewer sends. Stop with Control-C.
      --scene plays a deterministic reference scene (idle, typing, scroll, windowDrag, photo,
      resize) instead: with --scene-fps, frames change at that rate like a real app (a frame
      the viewer hasn't taken yet holds the scene back, as a server coalesces); without it,
      one frame per incremental request, as fast as the viewer asks. vnc-bench uses 60. --echo answers pointer events with a marker. --port 0
      picks a free port; the "Serving VNC on 127.0.0.1:PORT" line names it.
      """

    struct Options {
      var port: UInt16 = 5901
      var password: String? = "secret"
      var width = 1280
      var height = 800
      var fps = 10
      var encoding: RFBEncoding = .zrle
      var scene: RFBLoopbackScene.Kind?
      var seed: UInt64 = 1
      var echo = false
      var sceneFramesPerSecond: Int?
      var requestedOnly = false

      init(arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
          func value() throws -> String {
            guard let value = iterator.next() else { throw Failure("\(argument) needs a value") }
            return value
          }
          switch argument {
          case "--port": port = try UInt16(value()) ?? { throw Failure("invalid port") }()
          case "--password": password = try value()
          case "--no-password": password = nil
          case "--size":
            let parts = try value().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw Failure("--size expects WIDTHxHEIGHT") }
            (width, height) = (parts[0], parts[1])
          case "--scene":
            let name = try value()
            scene = try RFBLoopbackScene.Kind(rawValue: name) ?? { throw Failure("unknown scene \(name)") }()
          case "--seed": seed = try UInt64(value()) ?? { throw Failure("invalid seed") }()
          case "--echo": echo = true
          case "--requested-only": requestedOnly = true
          case "--scene-fps":
            let fps = try Int(value()) ?? 0
            guard (1...240).contains(fps) else { throw Failure("--scene-fps must be 1…240") }
            sceneFramesPerSecond = fps
          case "--fps": fps = try max(1, min(60, Int(value()) ?? 10))
          case "--encoding":
            switch try value() {
            case "zrle": encoding = .zrle
            case "raw": encoding = .raw
            case let other: throw Failure("unknown encoding \(other)")
            }
          default: throw Failure("unknown argument \(argument)\n\(usage)")
          }
        }
      }
    }

    static func main(arguments: [String]) {
      if arguments.contains("--help") { print(usage); return }
      setvbuf(stdout, nil, _IOLBF, 0)  // the input log is read live from a redirected stdout
      do {
        let options = try Options(arguments: arguments)
        Task { @MainActor in
          do { try await serve(options) } catch {
            FileHandle.standardError.write(Data("vnc-server: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
          }
        }
        RunLoop.main.run()
      } catch {
        FileHandle.standardError.write(Data("vnc-server: \(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
      }
    }

    @MainActor
    static func serve(_ options: Options) async throws {
      var configuration = RFBLoopbackServer.Configuration()
      configuration.port = options.port == 0 ? nil : options.port
      configuration.echoPointer = options.echo
      // A modern server: pushed updates paced by fences (851-2312), unless --requested-only.
      // A scene played on request needs requests, so it implies --requested-only (851-2336).
      let requestedOnly = options.requestedOnly || (options.scene != nil && options.sceneFramesPerSecond == nil)
      configuration.continuousUpdates = !requestedOnly
      configuration.fences = !requestedOnly
      configuration.desktopResize = .accept
      configuration.negotiateEncoding = true  // the client's preference (Tight first), as a real server (851-2313)
      configuration.password = options.password
      configuration.securityTypes = [
        options.password == nil ? RFBSecurityType.none.rawValue : RFBSecurityType.vncAuthentication.rawValue
      ]
      configuration.width = options.width
      configuration.height = options.height
      configuration.name = "Codevisor rig \(options.width)×\(options.height)"
      configuration.encoding = options.encoding
      let server = try await RFBLoopbackServer(configuration: configuration)
      if let kind = options.scene {
        let pace = options.sceneFramesPerSecond.map { "\($0) fps" } ?? "on request"
        print("Serving VNC on 127.0.0.1:\(server.port) (scene \(kind.rawValue), seed \(options.seed), \(pace))")
        let scene = SceneState(RFBLoopbackScene(kind: kind, seed: options.seed))
        if let fps = options.sceneFramesPerSecond {
          // Time-paced: the desktop changes at `fps` whatever the viewer does.
          let interval = Duration.seconds(1) / fps
          var next = ContinuousClock.now
          while true {
            next += interval
            try await Task.sleep(until: next, clock: .continuous)
            scene.play(on: server)
          }
        }
        // Each incremental request gets the next frame; the request itself then flushes it.
        server.onClientMessage = { [weak server] message in
          guard let server, case .framebufferUpdateRequest(true, _) = message else { return }
          scene.play(on: server)
        }
        while true { try await Task.sleep(for: .seconds(3600)) }  // `server` lives as long as this frame
      }
      let log = InputLog()
      server.onClientMessage = { log.record($0) }
      print(
        "Serving VNC on 127.0.0.1:\(server.port) (\(options.password.map { "password \($0)" } ?? "no password"), "
          + "\(options.width)×\(options.height), \(options.encoding), \(options.fps) fps)")
      let full = RFBRectangle(x: 0, y: 0, width: options.width, height: options.height)
      var painter = Painter(width: options.width, height: options.height)
      while true {
        try await Task.sleep(for: .milliseconds(1000 / options.fps))
        try server.paint(full, pixels: painter.nextFrame())
        if server.wantsUpdate {
          server.enqueue([options.encoding == .zrle ? .zrle(full) : .raw(full)])
        }
      }
    }

    /// The scene a message handler advances, shared across the server's connection task.
    final class SceneState: @unchecked Sendable {
      private let lock = NSLock()
      private var scene: RFBLoopbackScene
      init(_ scene: RFBLoopbackScene) { self.scene = scene }
      func play(on server: RFBLoopbackServer) {
        lock.withLock { _ = try? server.play(&scene) }
      }
    }

    /// A gradient, a sweeping bar and an orbiting square: enough to see motion, tearing and colour order.
    struct Painter {
      let width: Int
      let height: Int
      var tick = 0
      private var pixels: [UInt8]

      init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
      }

      mutating func nextFrame() -> [UInt8] {
        tick += 1
        let barX = (tick * 8) % width
        let angle = Double(tick) / 20
        let squareX = Int(Double(width) / 2 + cos(angle) * Double(width) / 4)
        let squareY = Int(Double(height) / 2 + sin(angle) * Double(height) / 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
          for y in 0..<height {
            let green = UInt8(y * 255 / max(1, height - 1))
            for x in 0..<width {
              let index = (y * width + x) * 4
              let inBar = (x - barX + width) % width < 16
              let inSquare = abs(x - squareX) < 40 && abs(y - squareY) < 40
              if inSquare {
                buffer[index] = 40; buffer[index + 1] = 40; buffer[index + 2] = 230
              } else if inBar {
                buffer[index] = 255; buffer[index + 1] = 255; buffer[index + 2] = 255
              } else {
                buffer[index] = UInt8(x * 255 / max(1, width - 1)); buffer[index + 1] = green; buffer[index + 2] = 60
              }
              buffer[index + 3] = 255
            }
          }
        }
        return pixels
      }
    }

    /// Prints keys, button changes and clipboard text; pointer motion is counted, not printed.
    final class InputLog: @unchecked Sendable {
      private let lock = NSLock()
      private var buttons: UInt8 = 0
      private var moves = 0

      func record(_ message: RFBClientMessage) {
        lock.withLock {
          switch message {
          case .keyEvent(let keysym, let down):
            print("key \(String(keysym, radix: 16)) \(down ? "down" : "up")")
          case .pointerEvent(let mask, let x, let y):
            if mask != buttons {
              print("buttons \(String(mask, radix: 2)) at \(x),\(y)")
              buttons = mask
            } else {
              moves += 1
              if moves % 100 == 0 { print("pointer at \(x),\(y) (\(moves) moves)") }
            }
          case .clientCutText(let text):
            print("clipboard: \(text)")
          default:
            break
          }
        }
      }
    }

    struct Failure: LocalizedError {
      let message: String
      init(_ message: String) { self.message = message }
      var errorDescription: String? { message }
    }
  }
#endif
