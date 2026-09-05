import AppKit

/// Recording remains visible and stoppable even between agent tool calls.
@MainActor
final class ComputerUseRecordingStatusItem: NSObject {
  static let shared = ComputerUseRecordingStatusItem()
  private var item: NSStatusItem?
  private var recordings: [String: (ComputerUseRecording, String)] = [:]

  func add(_ recording: ComputerUseRecording, title: String, agentLabel: String?) {
    recordings[recording.id] = (recording, agentLabel.map { "\(title) — \($0)" } ?? title)
    refresh()
  }

  func remove(_ id: String) {
    recordings.removeValue(forKey: id)
    refresh()
  }

  private func refresh() {
    guard !recordings.isEmpty else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      return
    }
    let status = item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item = status
    status.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Screen recording")
    status.button?.contentTintColor = .systemRed
    status.button?.toolTip = "Codevisor is recording"
    let menu = NSMenu()
    menu.addItem(withTitle: "Codevisor screen recording", action: nil, keyEquivalent: "")
    for (id, entry) in recordings.sorted(by: { $0.key < $1.key }) {
      let stop = NSMenuItem(
        title: "Stop recording: \(entry.1)", action: #selector(stopRecording(_:)), keyEquivalent: "")
      stop.target = self
      stop.representedObject = id
      menu.addItem(stop)
    }
    status.menu = menu
  }

  @objc private func stopRecording(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String, let recording = recordings[id]?.0 else { return }
    sender.isEnabled = false
    DispatchQueue.global(qos: .userInitiated).async { try? recording.stop(reason: "user_stopped") }
  }
}
