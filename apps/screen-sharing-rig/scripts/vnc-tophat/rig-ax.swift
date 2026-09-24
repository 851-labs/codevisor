// Drives the Screen Sharing rig through the Accessibility API for
// `bun run vnc:tophat` (docs/plans/vnc-validation.md, layer L4). It never
// moves the pointer or types; presses and selections are AX actions, so the
// rig can stay in the background. Compiled and cached by apps/screen-sharing-rig/scripts/vnc-tophat.mjs.
//
//   rig-ax PID texts                 every static text, one per line
//   rig-ax PID press LABEL           AXPress the first element labelled LABEL
//   rig-ax PID pressnth ROLE N       AXPress the Nth element of ROLE (1-based)
//   rig-ax PID select TEXT           select the sidebar row containing TEXT
//   rig-ax PID menu TITLE            AXPress a menu bar item titled TITLE
//   rig-ax PID window                "title<TAB>windowNumber<TAB>width<TAB>height"
//   rig-ax PID resize W H            set the main window's size
//   rig-ax PID wait TEXT SECONDS     until a static text contains TEXT
//   rig-ax PID has ROLE LABEL        an element of ROLE labelled LABEL exists (e.g. a pop-up's value)
//   rig-ax PID colours PNG           "N B": distinct colours on a grid over the image's right 3/4 and lower
//                                    3/4 (the video, clear of sidebar and toolbar), and the larger share of
//                                    near-black samples in that area's right half or bottom half. A blank
//                                    frame has 1 colour; a half-repainted desktop has a half that is ~all black
// Exit status 0 on success, 1 when the element or text isn't there.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[1]) else {
  FileHandle.standardError.write(Data("usage: rig-ax PID COMMAND [ARGS]\n".utf8))
  exit(2)
}
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  AXUIElementCopyAttributeValue(element, name as CFString, &value)
  return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String { attribute(element, kAXRoleAttribute) as? String ?? "" }

func label(_ element: AXUIElement) -> String {
  [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { attribute(element, $0) as? String }
    .first { !$0.isEmpty } ?? ""
}

/// Depth-first; stops when `visit` returns true.
@discardableResult
func walk(_ element: AXUIElement, _ visit: (AXUIElement) -> Bool) -> Bool {
  if visit(element) { return true }
  for child in children(element) where walk(child, visit) { return true }
  return false
}

func windows() -> [AXUIElement] { (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

func texts() -> [String] {
  var found: [String] = []
  for window in windows() {
    walk(window) { element in
      if role(element) == "AXStaticText" { found.append(label(element)) }
      return false
    }
  }
  return found
}

func press(_ element: AXUIElement) -> Bool { AXUIElementPerformAction(element, kAXPressAction as CFString) == .success }

func done(_ ok: Bool, _ message: String = "") -> Never {
  if !message.isEmpty { print(message) }
  exit(ok ? 0 : 1)
}

switch arguments[2] {
case "texts":
  print(texts().joined(separator: "\n"))
  done(true)

case "press" where arguments.count == 4:
  let wanted = arguments[3]
  var pressed = false
  for window in windows() where !pressed {
    walk(window) { element in
      guard label(element) == wanted,
        [
          "AXButton", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXCheckBox",
        ]
        .contains(role(element))
      else { return false }
      pressed = press(element)
      return true
    }
  }
  // Pop-up menus open outside the window tree.
  if !pressed {
    walk(app) { element in
      guard role(element) == "AXMenuItem", label(element) == wanted else { return false }
      pressed = press(element)
      return true
    }
  }
  done(pressed, pressed ? "" : "no element labelled \(wanted)")

case "pressnth" where arguments.count == 5:
  let wanted = arguments[3]
  guard let index = Int(arguments[4]) else { done(false, "N must be a number") }
  var seen = 0
  var pressed = false
  for window in windows() where !pressed {
    walk(window) { element in
      guard role(element) == wanted else { return false }
      seen += 1
      guard seen == index else { return false }
      pressed = press(element)
      return true
    }
  }
  done(pressed, pressed ? "" : "no \(wanted) #\(index)")

case "select" where arguments.count == 4:
  let wanted = arguments[3]
  var selected = false
  for window in windows() where !selected {
    walk(window) { element in
      guard role(element) == "AXRow" else { return false }
      var matches = false
      walk(element) { inner in
        matches = label(inner) == wanted
        return matches
      }
      guard matches else { return false }
      selected = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success
      return true
    }
  }
  done(selected, selected ? "" : "no sidebar row \(wanted)")

case "menu" where arguments.count == 4:
  let wanted = arguments[3]
  guard let bar = attribute(app, kAXMenuBarAttribute) else { done(false, "no menu bar") }
  var pressed = false
  walk(bar as! AXUIElement) { element in
    guard role(element) == "AXMenuItem", label(element) == wanted else { return false }
    pressed = press(element)
    return true
  }
  done(pressed, pressed ? "" : "no menu item \(wanted)")

case "window":
  guard let window = windows().first else { done(false, "no window") }
  let title = attribute(window, kAXTitleAttribute) as? String ?? ""
  var size = CGSize.zero
  if let value = attribute(window, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
  // The CGWindow number for window-only screenshots.
  let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
  // The largest normal-layer window: a popover (Connection Details) is a window of its own.
  func area(_ info: [String: Any]) -> Double {
    let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
  }
  let number =
    list.filter {
      ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && (($0[kCGWindowBounds as String] as? [String: Double])?["Height"] ?? 0) > 200
    }.max { area($0) < area($1) }?[kCGWindowNumber as String] as? Int ?? 0
  done(number != 0, "\(title)\t\(number)\t\(Int(size.width))\t\(Int(size.height))")

case "resize" where arguments.count == 5:
  guard let window = windows().first, let width = Double(arguments[3]), let height = Double(arguments[4]) else {
    done(false, "no window or bad size")
  }
  var size = CGSize(width: width, height: height)
  let value = AXValueCreate(.cgSize, &size)!
  done(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success)

case "has" where arguments.count == 5:
  let (wanted, text) = (arguments[3], arguments[4])
  var found = false
  for window in windows() where !found {
    walk(window) { element in
      found = role(element) == wanted && label(element) == text
      return found
    }
  }
  done(found, found ? "" : "no \(wanted) labelled \(text)")

case "wait" where arguments.count == 5:
  // A verification tool, not a unit test: polling the live app is the point.
  let wanted = arguments[3]
  let deadline = Date().addingTimeInterval(Double(arguments[4]) ?? 10)
  while Date() < deadline {
    if texts().contains(where: { $0.contains(wanted) }) { done(true) }
    Thread.sleep(forTimeInterval: 0.25)
  }
  done(false, "no text containing \(wanted)")

case "colours" where arguments.count == 4:
  guard let image = NSImage(contentsOfFile: arguments[3]),
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
    let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
  else { done(false, "unreadable image") }
  let step = cg.bitsPerPixel / 8
  var colours = Set<UInt32>()
  // [right half, bottom half] of the sampled area: samples and near-black samples.
  var halves = [(0, 0), (0, 0)]
  for y in stride(from: cg.height / 4, to: cg.height, by: max(1, cg.height / 60)) {
    for x in stride(from: cg.width / 4, to: cg.width, by: max(1, cg.width / 60)) {
      let offset = y * cg.bytesPerRow + x * step
      colours.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
      let dark = bytes[offset] < 12 && bytes[offset + 1] < 12 && bytes[offset + 2] < 12
      let right = x >= cg.width / 4 + (cg.width * 3 / 4) / 2, bottom = y >= cg.height / 4 + (cg.height * 3 / 4) / 2
      for (index, inside) in [right, bottom].enumerated() where inside {
        halves[index].0 += 1
        if dark { halves[index].1 += 1 }
      }
    }
  }
  let black = halves.map { Double($0.1) / Double(max($0.0, 1)) }.max() ?? 1
  done(true, "\(colours.count) \(black)")

default:
  done(false, "unknown command \(arguments.dropFirst(2).joined(separator: " "))")
}
