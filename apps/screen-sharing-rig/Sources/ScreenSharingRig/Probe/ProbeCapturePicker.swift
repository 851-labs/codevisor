import AppKit
import ScreenSharing
@preconcurrency import ScreenCaptureKit

/// A diagnostic process owns one picker and one stream. Keep the picker active
/// until capture stops so the system can display and revoke the selected share.
@MainActor
final class ProbeCapturePicker: NSObject, SCContentSharingPickerObserver {
  private var selection: CheckedContinuation<Void, any Error>?
  private var selectedFilter: SCContentFilter?
  private var timeout: Task<Void, Never>?
  private var active = false

  func choose(window: Bool = false) async throws -> SCContentFilter {
    let picker = SCContentSharingPicker.shared
    var configuration = SCContentSharingPickerConfiguration()
    configuration.allowedPickerModes = window ? [.singleWindow] : [.singleDisplay]
    configuration.allowsChangingSelectedContent = false
    picker.defaultConfiguration = configuration
    picker.maximumStreamCount = 1
    picker.add(self)
    active = true
    picker.isActive = true
    NSApplication.shared.activate()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        selection = continuation
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(120)) } catch { return }
          self?.finish(.failure(ScreenSharingError.unavailable("Capture selection timed out.")))
        }
        picker.present(using: window ? .window : .display)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
    guard let selectedFilter else { throw ScreenSharingError.unavailable("No capture content was selected.") }
    return selectedFilter
  }

  func stop() {
    finish(.failure(CancellationError()))
    if active {
      let picker = SCContentSharingPicker.shared
      picker.isActive = false
      picker.remove(self)
      active = false
    }
  }

  private func finish(_ result: Result<SCContentFilter, any Error>) {
    timeout?.cancel()
    timeout = nil
    let continuation = selection
    selection = nil
    guard let continuation else { return }
    switch result {
    case .success(let filter):
      selectedFilter = filter
      continuation.resume()
    case .failure(let error): continuation.resume(throwing: error)
    }
  }

  nonisolated func contentSharingPicker(
    _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
  ) {
    Task { @MainActor [weak self] in self?.finish(.success(filter)) }
  }

  nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
    Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
  }

  nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
    Task { @MainActor [weak self] in self?.finish(.failure(error)) }
  }
}
