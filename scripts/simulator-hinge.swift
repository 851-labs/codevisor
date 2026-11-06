import Darwin
import Foundation
import ObjectiveC
import XPC

struct Failure: Error, CustomStringConvertible {
  let description: String
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let angle = Int(arguments[2]), (0...180).contains(angle) else {
  FileHandle.standardError.write(Data("Usage: simulator-hinge.swift <udid> <degrees 0-180>\n".utf8))
  exit(64)
}
let udid = arguments[1]
let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? selectedDeveloperDirectory()
let feature = "com.apple.coredevice.feature.remote.hid.vendordefined"

func selectedDeveloperDirectory() -> String {
  let pipe = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
  process.arguments = ["-p"]
  process.standardOutput = pipe
  try? process.run()
  process.waitUntilExit()
  return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func implementation<T>(_ target: AnyObject, _ name: String, as type: T.Type) -> T? {
  guard let cls = object_getClass(target), let method = class_getMethodImplementation(cls, NSSelectorFromString(name))
  else { return nil }
  return unsafeBitCast(method, to: type)
}

func loadSimulatorFrameworks() throws {
  let simulatorKit = [
    "\(developerDirectory)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit",
    "\(developerDirectory)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
  ].first { FileManager.default.fileExists(atPath: $0) }
  guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
    let simulatorKit, dlopen(simulatorKit, RTLD_NOW) != nil
  else { throw Failure(description: "Couldn't load CoreSimulator from \(developerDirectory)") }
}

func device() throws -> NSObject {
  guard let context = NSClassFromString("SimServiceContext") else { throw Failure(description: "No SimServiceContext") }
  typealias Shared =
    @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
  typealias DefaultSet = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
  let sharedSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
  var error: NSError?
  guard let method = class_getClassMethod(context, sharedSelector),
    let shared = unsafeBitCast(method_getImplementation(method), to: Shared.self)(
      context, sharedSelector, developerDirectory as NSString, &error),
    let set = implementation(shared, "defaultDeviceSetWithError:", as: DefaultSet.self)?(
      shared, NSSelectorFromString("defaultDeviceSetWithError:"), &error),
    let devices = set.perform(NSSelectorFromString("devicesByUDID"))?.takeUnretainedValue() as? NSDictionary,
    let uuid = NSUUID(uuidString: udid), let device = devices[uuid] as? NSObject
  else { throw Failure(description: error?.localizedDescription ?? "No simulator \(udid)") }
  return device
}

func connection(to device: NSObject) throws -> xpc_connection_t {
  typealias Lookup =
    @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> mach_port_t
  typealias EndpointFromPort = @convention(c) (mach_port_t, UInt64, UInt64) -> xpc_object_t?
  typealias ConnectionFromEndpoint = @convention(c) (xpc_object_t) -> xpc_connection_t?
  typealias EnableHostBridge = @convention(c) (xpc_connection_t) -> Void
  var error: NSError?
  let handle = UnsafeMutableRawPointer(bitPattern: -2)
  guard let lookup = implementation(device, "lookup:error:", as: Lookup.self) else {
    throw Failure(description: "CoreSimulator changed")
  }
  let port = lookup(device, NSSelectorFromString("lookup:error:"), feature as NSString, &error)
  guard port != 0, let endpointSymbol = dlsym(handle, "xpc_endpoint_create_mach_port_4sim"),
    let connectionSymbol = dlsym(handle, "xpc_connection_create_from_endpoint"),
    let bridgeSymbol = dlsym(handle, "xpc_connection_enable_sim2host_4sim"),
    let endpoint = unsafeBitCast(endpointSymbol, to: EndpointFromPort.self)(port, 0, 0),
    let connection = unsafeBitCast(connectionSymbol, to: ConnectionFromEndpoint.self)(endpoint)
  else { throw Failure(description: error?.localizedDescription ?? "\(udid) doesn't offer \(feature)") }
  unsafeBitCast(bridgeSymbol, to: EnableHostBridge.self)(connection)
  xpc_connection_set_event_handler(connection) { _ in }
  xpc_connection_resume(connection)
  return connection
}

func hingeEvent(_ degrees: Int) -> xpc_object_t {
  let state =
    "<dict><key>source</key><string>hinge-slider-control</string><key>type</key><string>range</string>"
    + "<key>value</key><integer>\(degrees)</integer></dict>"
  let data = Data(state.utf8)
  let payload = xpc_dictionary_create(nil, nil, 0)
  xpc_dictionary_set_uint64(payload, "usagePage", 0xFF61)
  xpc_dictionary_set_uint64(payload, "usage", 0x5B)
  xpc_dictionary_set_uint64(payload, "version", 0)
  data.withUnsafeBytes { bytes in xpc_dictionary_set_data(payload, "data", bytes.baseAddress!, data.count) }
  let message = xpc_dictionary_create(nil, nil, 0)
  xpc_dictionary_set_string(message, "messageType", "IndigoVendorDefinedEvent")
  xpc_dictionary_set_bool(message, "isBarrier", false)
  xpc_dictionary_set_string(message, "featureIdentifier", feature)
  xpc_dictionary_set_value(message, "payload", payload)
  return message
}

do {
  try loadSimulatorFrameworks()
  let connection = try connection(to: try device())
  let steps = 15
  for step in 0...steps {
    let progress = Double(step) / Double(steps)
    xpc_connection_send_message(connection, hingeEvent(Int((Double(angle) * (1 - pow(1 - progress, 3))).rounded())))
    usleep(20_000)
  }
  let delivered = DispatchSemaphore(value: 0)
  xpc_connection_send_barrier(connection) { delivered.signal() }
  delivered.wait()
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
