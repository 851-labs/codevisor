import AppKit
import CodevisorCore
import CodevisorCoreMac
import Foundation
import Sparkle
import os

/// Owns Sparkle for the lifetime of the app and adapts its native updater to
/// the observable model behind Settings › Updates. Sparkle never shows its
/// own windows: checks report into the model, and an install — whether the
/// user clicked Update here or a remote client asked this machine's server
/// to update — runs as one headless download → drain → install → relaunch
/// session with progress in the model.
@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
  private let model: AppUpdateModel
  private weak var localServer: (any LocalServerControlling)?
  private let serverAgent: MacServerAgentController
  private let instanceLease: AppInstanceLease
  private var updater: SPUUpdater!
  private var driver: HeadlessUserDriver!
  /// A helper inherits the app's singleton lock immediately before Sparkle
  /// takes over. It outlives this process and releases after the new bundle
  /// version is visible.
  private var updateLeaseHandoff: AppUpdateLeaseHandoff?
  /// True from an install's arming until it reports an outcome. Guards the
  /// handoff status writes a remote client polls through the server.
  private var installSessionActive = false
  /// The local server has been drained (and possibly stopped) for the
  /// install in flight; an abort after this point must bring it back.
  private var serverPreparedForUpdate = false

  init(
    model: AppUpdateModel,
    localServer: (any LocalServerControlling)?,
    serverAgent: MacServerAgentController,
    instanceLease: AppInstanceLease
  ) {
    self.model = model
    self.localServer = localServer
    self.serverAgent = serverAgent
    self.instanceLease = instanceLease
    super.init()
    // A raw SPUUpdater with a headless driver instead of
    // SPUStandardUpdaterController: the app's own Updates page is the
    // only update UI.
    driver = HeadlessUserDriver()
    driver.onProgress = { [weak self] progress in
      self?.report(progress)
    }
    updater = SPUUpdater(
      hostBundle: .main,
      applicationBundle: .main,
      userDriver: driver,
      delegate: self
    )
    do {
      try updater.start()
    } catch {
      model.reportFailure(error.localizedDescription)
    }
    // A fresh boot is the success path of an install (the relaunched app
    // IS the update): drop any stale handoff report, and re-assert this
    // machine's release channel for the bundled server — it answers
    // /v1/update from this preference, never a client's.
    AppUpdateHandoff.clearStatus()
    AppUpdateHandoff.writeChannel(allowsAlpha: model.allowsAlphaUpdates)
    model.checkHandler = { [weak self] _ in
      guard let self, !self.updater.sessionInProgress else { return }
      self.updater.checkForUpdateInformation()
    }
    model.installHandler = { [weak self] _ in
      self?.beginInstall()
    }
    model.unattendedInstallHandler = { [weak self] in
      self?.beginInstall()
    }
    model.channelChangeHandler = { [weak self] allowsAlpha in
      // The bundled server answers /v1/update from this machine's own
      // channel; keep its copy of the preference current.
      AppUpdateHandoff.writeChannel(allowsAlpha: allowsAlpha)
      self?.updater.resetUpdateCycle()
    }
  }

  /// Runs one headless check → download → install → relaunch cycle. Arms
  /// even when a session is already in progress (a background check may be
  /// mid-flight): the driver accepts whatever that session finds, and a
  /// fresh check starts as soon as Sparkle is free.
  private func beginInstall() {
    Log.updates.log("install: begin (session in progress: \(self.updater.sessionInProgress))")
    ServerLifecycleLog.default.note("update: install requested")
    installSessionActive = true
    serverPreparedForUpdate = false
    AppUpdateHandoff.writeStatus(state: "installing")
    model.reportProgress("Checking for the update…")
    driver.armInstall()
    Task { @MainActor [weak self] in
      // Sparkle runs one session at a time and ignores a check requested
      // during another; wait for the in-flight one (an information check
      // finishes in seconds) rather than dropping the install.
      for _ in 0..<50 {
        guard let self, self.installSessionActive else { return }
        if !self.updater.sessionInProgress {
          self.updater.checkForUpdates()
          return
        }
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
  }

  private func report(_ progress: HeadlessUserDriver.Progress) {
    switch progress {
    case let .downloading(fraction):
      model.reportProgress("Downloading…", fraction: fraction)
    case let .extracting(fraction):
      model.reportProgress("Preparing…", fraction: fraction)
    case .installing:
      model.reportProgress("Installing…")
    }
  }

  private func failInstall(_ message: String) {
    Log.updates.error("install: failed: \(message, privacy: .public)")
    ServerLifecycleLog.default.error("update: install failed: \(message)")
    installSessionActive = false
    serverPreparedForUpdate = false
    updateLeaseHandoff?.cancel()
    updateLeaseHandoff = nil
    AppUpdateHandoff.writeStatus(state: "failed", message: message)
    model.reportFailure(message)
    // The server may be holding prompts behind its restart drain (a remote
    // client's request drained it before handing off) or already be
    // stopped for an install that is not happening: release it and make
    // sure it is running. Harmless when neither applies.
    Task { @MainActor [weak self] in
      await self?.localServer?.abandonAppUpdate()
    }
  }

  /// Sparkle's installer tracks a single running instance of the app: with
  /// two, it swaps and deletes the bundle out from under the survivor,
  /// which then crashes in dyld. Refuse to install until only this one runs.
  private static func otherRunningInstanceCount() -> Int {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return 0 }
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let ownBundle = Bundle.main.bundleURL.standardizedFileURL
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0.processIdentifier != ownPid }
      .filter { $0.bundleURL?.standardizedFileURL == ownBundle }
      .count
  }

  // MARK: - SPUUpdaterDelegate

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    model.allowsAlphaUpdates ? ["alpha"] : []
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    if let developmentFeedURL = CodevisorAppVariant.developmentSparkleFeedURL {
      return developmentFeedURL
    }
    #if arch(x86_64)
      return "https://updates.codevisor.dev/appcast-x64.xml"
    #else
      return "https://updates.codevisor.dev/appcast-arm64.xml"
    #endif
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    Log.updates.log(
      "check: found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public)), installing: \(self.installSessionActive)"
    )
    let releasePageURL = item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
    model.reportAvailable(version: item.displayVersionString, releasePageURL: releasePageURL)
    if installSessionActive {
      // Committed from here: the row shows progress, the composer stops
      // accepting turns, and a quit request is not confirmed.
      model.reportInstalling(version: item.displayVersionString, releasePageURL: releasePageURL)
      model.reportProgress("Downloading…")
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    if installSessionActive {
      // The server's manifest (or this page) said "newer" but this
      // machine's Sparkle feed disagrees, usually a channel mismatch.
      failInstall(
        "This machine's update feed has no newer release. Check its Alpha updates setting."
      )
      return
    }
    model.reportUpToDate()
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    Log.updates.log("install: Sparkle will install \(item.displayVersionString, privacy: .public)")
    ServerLifecycleLog.default.note("update: installing \(item.displayVersionString)")
    if installSessionActive {
      AppUpdateHandoff.writeStatus(
        state: "installing",
        targetVersion: item.displayVersionString
      )
    }
    model.reportInstalling(
      version: item.displayVersionString,
      releasePageURL: item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
    )
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if installSessionActive {
      failInstall(error.localizedDescription)
      return
    }
    // "No update" is reported through updaterDidNotFindUpdate; only a
    // check that was still running has a failure worth showing.
    if case .checking = model.phase {
      model.reportFailure(error.localizedDescription)
    }
  }

  func updater(
    _ updater: SPUUpdater,
    shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    Task { @MainActor [weak self] in
      guard let self else {
        installHandler()
        return
      }
      let others = Self.otherRunningInstanceCount()
      Log.updates.log("install: relaunch postponed; other instances running: \(others)")
      guard others == 0 else {
        self.failInstall(
          others == 1
            ? "Another copy of Codevisor is running. Quit it, then update again."
            : "\(others) other copies of Codevisor are running. Quit them, then update again."
        )
        return
      }
      self.serverPreparedForUpdate = true
      self.model.reportProgress("Waiting for the server…")
      let prepared = await self.serverAgent.prepareForAppUpdate(localServer: self.localServer) {
        [weak self] status in
        self?.model.reportProgress(status)
      }
      guard prepared else {
        self.failInstall(
          "The Codevisor server could not be stopped safely. Restart Codevisor and try the update again."
        )
        return
      }
      // Server draining is asynchronous. Check once more at the actual
      // handoff boundary, then transfer the instance lease across our exit so
      // no process can enter between Sparkle's termination and relaunch.
      let lateOthers = Self.otherRunningInstanceCount()
      guard lateOthers == 0 else {
        self.failInstall(
          lateOthers == 1
            ? "Another copy of Codevisor started while preparing the update. Quit it, then update again."
            : "\(lateOthers) other copies of Codevisor started while preparing the update. Quit them, then update again."
        )
        return
      }
      do {
        self.updateLeaseHandoff = try self.instanceLease.beginUpdateHandoff(
          targetBundleVersion: item.versionString
        )
      } catch {
        self.failInstall(
          "Codevisor could not protect the app while installing the update: \(error.localizedDescription)"
        )
        return
      }
      self.model.reportProgress("Restarting…")
      Log.updates.log("install: server prepared; handing over to Sparkle for the relaunch")
      ServerLifecycleLog.default.note("update: server prepared, Sparkle relaunching the app")
      installHandler()
    }
    return true
  }
}
