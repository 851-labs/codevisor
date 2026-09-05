import ApplicationServices
import Foundation

/// Fetch observation fields in one IPC request per element. Unsupported
/// attributes are omitted; older providers can use individual reads.
struct ComputerUseElementAttributes {
  private let values: [String: CFTypeRef]
  static let identityNames = [
    kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute,
  ]

  init(_ element: AXUIElement) {
    let names =
      Self.identityNames + [
        kAXValueAttribute, kAXChildrenAttribute, kAXPositionAttribute,
        kAXSizeAttribute, kAXSelectedAttribute, kAXSelectedTextRangeAttribute, kAXEnabledAttribute,
      ]
    var raw: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
    if error == .success, let raw = raw as? [CFTypeRef], raw.count == names.count {
      values = Dictionary(
        uniqueKeysWithValues: zip(names, raw).filter { _, value in
          if CFGetTypeID(value) == CFNullGetTypeID() { return false }
          return CFGetTypeID(value) != AXValueGetTypeID() || AXValueGetType(value as! AXValue) != .axError
        })
    } else {
      values = Dictionary(
        uniqueKeysWithValues: names.compactMap { name in
          copyAttribute(element, name).map { (name, $0) }
        })
    }
  }

  func string(_ name: String) -> String? { values[name] as? String }
  subscript(_ name: String) -> CFTypeRef? { values[name] }
  var children: [AXUIElement] { values[kAXChildrenAttribute] as? [AXUIElement] ?? [] }
  var identity: String {
    let names = Self.identityNames + (string(kAXRoleAttribute) == "AXStaticText" ? [kAXValueAttribute] : [])
    return names.map { string($0) ?? "" }.joined(separator: "\u{1f}")
  }
  var frame: CGRect? {
    guard let position = values[kAXPositionAttribute], let size = values[kAXSizeAttribute],
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: point, size: dimensions)
  }
  var selection: CFRange? {
    guard let raw = values[kAXSelectedTextRangeAttribute], CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    return AXValueGetValue(raw as! AXValue, .cfRange, &range) ? range : nil
  }
}
