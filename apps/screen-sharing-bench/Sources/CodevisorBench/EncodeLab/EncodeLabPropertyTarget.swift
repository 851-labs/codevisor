import CoreFoundation

protocol EncodeLabPropertyTarget {
  func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus
  func copy(_ key: CFString) -> (OSStatus, CFTypeRef?)
  func main444Profile() throws -> CFString
}
