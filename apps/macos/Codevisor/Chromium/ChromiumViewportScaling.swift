import Foundation

nonisolated enum ChromiumViewportScaling {
  private static let pointerMethods: Set<String> = [
    "Input.dispatchMouseEvent", "Input.dispatchDragEvent", "Input.emulateTouchFromMouseEvent",
    "Input.synthesizeTapGesture", "Input.synthesizeScrollGesture", "Input.synthesizePinchGesture",
  ]

  static func params(for method: String, _ params: Data?, scale: Double) -> Data? {
    guard abs(scale - 1) > 0.0001, scale > 0, let params,
      var object = (try? JSONSerialization.jsonObject(with: params)) as? [String: Any]
    else { return params }

    if pointerMethods.contains(method) {
      object = scaledPoint(object, by: scale)
    } else if method == "Input.dispatchTouchEvent" {
      let points = object["touchPoints"] as? [[String: Any]] ?? []
      object["touchPoints"] = points.map { scaledPoint($0, by: scale) }
    } else {
      return params
    }
    return (try? JSONSerialization.data(withJSONObject: object)) ?? params
  }

  private static func scaledPoint(_ point: [String: Any], by scale: Double) -> [String: Any] {
    var point = point
    for axis in ["x", "y"] {
      if let value = (point[axis] as? NSNumber)?.doubleValue { point[axis] = value * scale }
    }
    return point
  }
}
