import CoreGraphics
import Darwin
import Foundation
import IOSurface
import ObjectiveC
import XPC

/// Xcode's simulator frameworks (CoreSimulator, SimulatorKit), reached at run time: loaded with
/// `dlopen` from the active developer directory and called through the Objective-C runtime, so
/// the app neither links them nor fails to launch without Xcode. Everything here is what
/// Simulator.app and Device Hub themselves use to show a device's screen and send it input.
enum SimulatorRuntime {
  struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  /// The developer directory `xcode-select` points at (or `DEVELOPER_DIR`).
  static let developerDirectory: String? = {
    if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !env.isEmpty { return env }
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Command Line Tools alone have no simulators.
    return path.hasSuffix("/Contents/Developer") ? path : nil
  }()

  /// Loads the frameworks once; false without a full Xcode.
  static let loaded: Bool = {
    guard let developer = developerDirectory else { return false }
    let coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    let simulatorKit = [
      "\(developer)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
      "\(developer)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
    ].first { FileManager.default.fileExists(atPath: $0) }
    guard dlopen(coreSimulator, RTLD_NOW | RTLD_GLOBAL) != nil, let simulatorKit,
      dlopen(simulatorKit, RTLD_NOW | RTLD_GLOBAL) != nil
    else { return false }
    return NSClassFromString("SimServiceContext") != nil
  }()

  // MARK: Objective-C messaging

  static func selector(_ name: String) -> Selector { NSSelectorFromString(name) }

  static func object(_ target: AnyObject, _ name: String) -> AnyObject? {
    (target as? NSObject)?.perform(selector(name))?.takeUnretainedValue()
  }

  static func implementation<T>(_ target: AnyObject, _ name: String, as type: T.Type) -> T? {
    guard let cls = object_getClass(target), let method = class_getMethodImplementation(cls, selector(name))
    else { return nil }
    return unsafeBitCast(method, to: type)
  }

  static func uint32(_ target: AnyObject, _ name: String) -> UInt32 {
    implementation(target, name, as: (@convention(c) (AnyObject, Selector) -> UInt32).self)?(target, selector(name))
      ?? 0
  }

  static func uint64(_ target: AnyObject, _ name: String) -> UInt64 {
    implementation(target, name, as: (@convention(c) (AnyObject, Selector) -> UInt64).self)?(target, selector(name))
      ?? 0
  }

  // MARK: Devices

  /// The user's default device set (what `simctl` and Device Hub show).
  static func deviceSet() throws -> NSObject {
    guard loaded, let developer = developerDirectory, let cls = NSClassFromString("SimServiceContext") else {
      throw Failure("Xcode's simulators aren't available on this Mac.")
    }
    typealias Shared =
      @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>)
      -> NSObject?
    let sharedSelector = selector("sharedServiceContextForDeveloperDir:error:")
    guard let method = class_getClassMethod(cls, sharedSelector) else { throw Failure("CoreSimulator changed.") }
    var error: NSError?
    guard
      let context = unsafeBitCast(method_getImplementation(method), to: Shared.self)(
        cls, sharedSelector, developer as NSString, &error)
    else { throw Failure(error?.localizedDescription ?? "CoreSimulator is unavailable.") }
    typealias DefaultSet =
      @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>)
      -> NSObject?
    guard
      let set = implementation(context, "defaultDeviceSetWithError:", as: DefaultSet.self)?(
        context, selector("defaultDeviceSetWithError:"), &error)
    else { throw Failure(error?.localizedDescription ?? "No simulator device set.") }
    return set
  }

  static func device(udid: String) throws -> NSObject {
    guard let uuid = NSUUID(uuidString: udid),
      let devices = object(try deviceSet(), "devicesByUDID") as? NSDictionary,
      let device = devices[uuid] as? NSObject
    else { throw Failure("That simulator no longer exists.") }
    return device
  }

  /// simctl's state values: 1 shutdown, 3 booted, others in between.
  static func isBooted(_ device: NSObject) -> Bool { uint64(device, "state") == 3 }

  /// The runtime's major version ("27.0" → 27), 0 when unknown.
  static func runtimeMajorVersion(_ device: NSObject) -> Int {
    guard let runtime = object(device, "runtime"), let version = object(runtime, "versionString") as? String
    else { return 0 }
    return Int(version.split(separator: ".").first ?? "") ?? 0
  }

  static func productFamily(_ device: NSObject) -> String {
    guard let type = object(device, "deviceType") else { return "iPhone" }
    return object(type, "productFamily") as? String ?? "iPhone"
  }

  /// The device type's capabilities.plist `displays`, by device name ("primary", "primary-1").
  static func displayCapabilities(_ device: NSObject) -> [String: [String: Any]] {
    guard let type = object(device, "deviceType"), let bundle = object(type, "bundle") as? Bundle,
      let url = bundle.url(forResource: "capabilities", withExtension: "plist"),
      let plist = NSDictionary(contentsOf: url) as? [String: Any],
      let capabilities = plist["capabilities"] as? [String: Any],
      let displays = capabilities["displays"] as? [[String: Any]]
    else { return [:] }
    var byName: [String: [String: Any]] = [:]
    for display in displays {
      if let name = display["deviceName"] as? String { byName[name] = display }
    }
    return byName
  }

  // MARK: Screens

  /// One of the device's integrated screens and its live framebuffer.
  struct Screen {
    let descriptor: NSObject
    let screenID: UInt32
    /// The device-type display it is ("primary", "primary-1").
    let name: String
    /// 0 integrated, 1 TV out, 2 CarPlay, 4 a resizable scene.
    let type: UInt64

    var surface: IOSurfaceRef? {
      guard let surface = SimulatorRuntime.object(descriptor, "framebufferSurface") else { return nil }
      return unsafeDowncast(surface, to: IOSurfaceRef.self)
    }
  }

  /// The device's screens. An Apple TV's only screen is its TV output.
  static func screens(_ device: NSObject) -> [Screen] {
    guard let io = object(device, "io") as? NSObject else { return [] }
    io.perform(selector("updateIOPorts"))
    guard let ports = object(io, "ioPorts") as? [NSObject] else { return [] }
    return ports.compactMap { port in
      guard object(port, "portIdentifier") as? String == "com.apple.framebuffer.display",
        let descriptor = object(port, "descriptor") as? NSObject,
        let properties = object(descriptor, "screenProperties")
      else { return nil }
      return Screen(
        descriptor: descriptor, screenID: uint32(properties, "screenID"),
        name: object(properties, "deviceName") as? String ?? "primary", type: uint64(properties, "screenType"))
    }
  }

  /// Registers for a screen's frames; the returned token unregisters. Registering is also
  /// what wires the screen's framebuffer to this process.
  static func observe(
    _ screen: Screen, queue: DispatchQueue, frame: @escaping @convention(block) () -> Void,
    surfacesChanged: @escaping @convention(block) () -> Void
  ) -> UUID? {
    typealias Register =
      @convention(c) (
        AnyObject, Selector, NSUUID, DispatchQueue, @escaping @convention(block) () -> Void,
        @escaping @convention(block) () -> Void, @escaping @convention(block) () -> Void
      ) -> Void
    let name =
      "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
    guard let register = implementation(screen.descriptor, name, as: Register.self) else { return nil }
    let uuid = UUID()
    register(screen.descriptor, selector(name), uuid as NSUUID, queue, frame, surfacesChanged, surfacesChanged)
    return uuid
  }

  static func stopObserving(_ screen: Screen, token: UUID) {
    typealias Unregister = @convention(c) (AnyObject, Selector, NSUUID) -> Void
    let name = "unregisterScreenCallbacksWithUUID:"
    implementation(screen.descriptor, name, as: Unregister.self)?(screen.descriptor, selector(name), token as NSUUID)
  }

  // MARK: Guest services

  /// A connection to a CoreDevice feature service inside the simulated OS (iOS 27 and later),
  /// over the simulator's host bridge. Kept open: the guest tears its virtual HID devices down
  /// when the host side disconnects, and drops what hadn't drained.
  final class GuestService: @unchecked Sendable {
    let feature: String
    private let connection: xpc_connection_t

    init(device: NSObject, feature: String) throws {
      typealias Lookup =
        @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>)
        -> mach_port_t
      typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
      typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> xpc_connection_t?
      typealias EnableHostBridge = @convention(c) (xpc_connection_t) -> Void
      var error: NSError?
      guard
        let lookup = SimulatorRuntime.implementation(device, "lookup:error:", as: Lookup.self)
      else { throw Failure("CoreSimulator changed.") }
      let port = lookup(device, SimulatorRuntime.selector("lookup:error:"), feature as NSString, &error)
      let handle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
      guard port != 0, let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
        let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
        let bridgeSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim"),
        let endpoint = unsafeBitCast(endpointSymbol, to: EndpointFromPort.self)(port, 0, 0),
        let connection = unsafeBitCast(connectionSymbol, to: ConnectionFromEndpoint.self)(endpoint)
      else { throw Failure(error?.localizedDescription ?? "The simulator doesn't offer \(feature).") }
      // Without this the guest never sees the payload.
      unsafeBitCast(bridgeSymbol, to: EnableHostBridge.self)(connection)
      xpc_connection_set_event_handler(connection) { _ in }
      xpc_connection_resume(connection)
      self.feature = feature
      self.connection = connection
    }

    deinit { xpc_connection_cancel(connection) }

    private func envelope(_ type: String, _ payload: xpc_object_t) -> xpc_object_t {
      let message = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_string(message, "messageType", type)
      xpc_dictionary_set_bool(message, "isBarrier", false)
      xpc_dictionary_set_string(message, "featureIdentifier", feature)
      xpc_dictionary_set_value(message, "payload", payload)
      return message
    }

    func send(_ type: String, _ payload: xpc_object_t) {
      xpc_connection_send_message(connection, envelope(type, payload))
    }

    /// A request with a reply; blocks, so call it off the main thread.
    func request(_ type: String, _ payload: xpc_object_t) -> xpc_object_t {
      xpc_connection_send_message_with_reply_sync(connection, envelope(type, payload))
    }
  }

  // MARK: Legacy HID (runtimes before iOS 27)

  /// SimulatorKit's HID client and its Indigo message builders.
  final class LegacyHID: @unchecked Sendable {
    typealias Mouse =
      @convention(c) (
        UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, Int32, CGFloat, CGFloat, UInt32
      ) -> UnsafeMutableRawPointer?
    typealias Arbitrary = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias Keyboard = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private let mouse: Mouse
    private let arbitrary: Arbitrary
    private let keyboard: Keyboard
    private let client: NSObject
    private let queue = DispatchQueue(label: "codevisor.simulator.legacy-hid")

    init(device: NSObject) throws {
      let handle = UnsafeMutableRawPointer(bitPattern: -2)
      guard let mouse = dlsym(handle, "IndigoHIDMessageForMouseNSEvent"),
        let arbitrary = dlsym(handle, "IndigoHIDMessageForHIDArbitrary"),
        let keyboard = dlsym(handle, "IndigoHIDMessageForKeyboardArbitrary"),
        let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
      else { throw Failure("SimulatorKit changed.") }
      self.mouse = unsafeBitCast(mouse, to: Mouse.self)
      self.arbitrary = unsafeBitCast(arbitrary, to: Arbitrary.self)
      self.keyboard = unsafeBitCast(keyboard, to: Keyboard.self)
      typealias Initialize =
        @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>)
        -> NSObject?
      let initializer = SimulatorRuntime.selector("initWithDevice:error:")
      guard let method = class_getMethodImplementation(cls, initializer) else { throw Failure("SimulatorKit changed.") }
      var error: NSError?
      guard
        let client = unsafeBitCast(method, to: Initialize.self)(
          class_createInstance(cls, 0) as AnyObject, initializer, device, &error)
      else { throw Failure(error?.localizedDescription ?? "Can't send input to the simulator.") }
      self.client = client
    }

    private func send(_ message: UnsafeMutableRawPointer?) {
      guard let message else { return }
      typealias Send =
        @convention(c) (
          AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, DispatchQueue,
          @escaping @convention(block) (NSError?) -> Void
        ) -> Void
      let name = "sendWithMessage:freeWhenDone:completionQueue:completion:"
      SimulatorRuntime.implementation(client, name, as: Send.self)?(
        client, SimulatorRuntime.selector(name), message, true, queue, { _ in })
    }

    /// Fingers in framebuffer-normalized coordinates; `down` false lifts them.
    func touch(_ first: CGPoint, _ second: CGPoint?, down: Bool, edge: UInt32) {
      var one = first
      if var two = second {
        send(mouse(&one, &two, 0x32, down ? 1 : 2, 1, 1, 0))
      } else {
        send(mouse(&one, nil, 0x32, down ? 1 : 2, 1, 1, edge))
      }
    }

    func button(page: UInt32, usage: UInt32, down: Bool) { send(arbitrary(0x32, page, usage, down ? 1 : 2)) }
    func key(_ usage: UInt32, down: Bool) { send(keyboard(usage, down ? 1 : 2)) }
  }

  /// Turns the device the pre-CoreDevice way: a GSEvent to SpringBoard's workspace port.
  /// Values: 1 portrait, 2 upside down, 3 landscape right, 4 landscape left.
  static func sendOrientationEvent(device: NSObject, value: UInt32) {
    typealias Lookup =
      @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>)
      -> mach_port_t
    var error: NSError?
    guard let lookup = implementation(device, "lookup:error:", as: Lookup.self) else { return }
    let port = lookup(device, selector("lookup:error:"), "PurpleWorkspacePort", &error)
    guard port != 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 112)
    _ = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
      guard let base = raw.baseAddress else { return KERN_FAILURE }
      let header = base.assumingMemoryBound(to: mach_msg_header_t.self)
      header.pointee.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
      header.pointee.msgh_size = 108
      header.pointee.msgh_remote_port = port
      header.pointee.msgh_id = 0x7B
      // GSEventTypeDeviceOrientationChanged with the host flag, then the record.
      base.storeBytes(of: UInt32(50 | 0x20000), toByteOffset: 0x18, as: UInt32.self)
      base.storeBytes(of: UInt32(4), toByteOffset: 0x48, as: UInt32.self)
      base.storeBytes(of: value, toByteOffset: 0x4C, as: UInt32.self)
      return mach_msg(
        header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, mach_port_t(MACH_PORT_NULL), 2000,
        mach_port_t(MACH_PORT_NULL))
    }
  }
}
