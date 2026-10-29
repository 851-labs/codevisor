import Darwin

enum MachineModel {
  static var chip: String {
    var size = 0
    guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }

    var name = [CChar](repeating: 0, count: size)
    guard sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0) == 0 else { return "unknown" }

    return String(decoding: name.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
  }
}
