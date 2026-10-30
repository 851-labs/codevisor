import CoreFoundation

struct EncodeLabVCPPropertyTarget: EncodeLabPropertyTarget {
  static let main444 = "HEVC_Main444_AutoLevel"

  let api: EncodeLabVideoProcessing
  let session: AnyObject

  func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
    api.setProperty(session, key, value)
  }

  func copy(_ key: CFString) -> (OSStatus, CFTypeRef?) {
    var value: Unmanaged<CFTypeRef>?
    let status = api.copyProperty(session, key, nil, &value)
    return (status, value?.takeRetainedValue())
  }

  func main444Profile() throws -> CFString {
    Self.main444 as CFString
  }
}
