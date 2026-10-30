import VideoToolbox

struct EncodeLabVTPropertyTarget: EncodeLabPropertyTarget {
  let session: VTCompressionSession

  func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
    VTSessionSetProperty(session, key: key, value: value)
  }

  func copy(_ key: CFString) -> (OSStatus, CFTypeRef?) {
    var value: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: key, allocator: nil, valueOut: &value)
    return (status, value?.takeRetainedValue())
  }

  func main444Profile() throws -> CFString {
    var supported: CFDictionary?
    let status = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported)
    guard status == noErr else { throw EncodeLabError.property("supported properties", status) }

    let info = (supported as? [String: Any])?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
    let profiles = info?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
    guard let profile = profiles.first(where: { $0.contains("_Main444_") }) else {
      throw EncodeLabError.property("Main444 profile", kVTPropertyNotSupportedErr)
    }

    return profile as CFString
  }
}
