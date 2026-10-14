import AppKit
import CodevisorCore
import CodevisorCoreMac
import Foundation
import Sparkle
import os

@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
  private let model: AppUpdateModel
  private weak var localServer: (any LocalServerControlling)?
  private let serverAgent: MacServerAgentController
  private let instanceLease: AppInstanceLease
  private var updater: SPUUpdater!
  private var driver: HeadlessUserDriver!
  private var updateLeaseHandoff: AppUpdateLeaseHandoff?
  private var installSessionActive = false
  private var serverPreparedForUpdate = false
  private var installTargetBuild: Int?
  private var progressThrottle = AppUpdateProgressThrottle()

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
    updater.automaticallyChecksForUpdates = false
    AppUpdateHandoff.enqueueClearStatus()
    AppUpdateHandoff.enqueueChannel(allowsAlpha: model.allowsAlphaUpdates)
    if let feedURL = feedURLString(for: updater) {
      AppUpdateHandoff.enqueueFeedURL(feedURL)
    }
    model.checkHandler = { [weak self] in
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
      AppUpdateHandoff.enqueueChannel(allowsAlpha: allowsAlpha)
      self?.updater.resetUpdateCycle()
    }
  }

  private func beginInstall() {
    Log.updates.log("install: begin (session in progress: \(self.updater.sessionInProgress))")
    ServerLifecycleLog.default.note("update: install requested")
    installSessionActive = true
    serverPreparedForUpdate = false
    installTargetBuild = nil
    reportProgress("Checking for the update…")
    driver.armInstall()
    Task { @MainActor [weak self] in
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

  private func reportProgress(_ message: String?, fraction: Double? = nil) {
    progressThrottle.reset()
    publishProgress(message, fraction: fraction)
  }

  private func reportThrottledProgress(_ message: String, fraction: Double?) {
    guard progressThrottle.shouldReport(message: message, fraction: fraction, at: .now) else { return }
    publishProgress(message, fraction: fraction)
  }

  private func publishProgress(_ message: String?, fraction: Double?) {
    model.reportProgress(message, fraction: fraction)
    guard installSessionActive else { return }
    AppUpdateHandoff.enqueueStatus(
      state: "installing",
      message: message,
      targetVersion: model.availableRelease?.version,
      targetBuildNumber: installTargetBuild,
      progress: model.progress
    )
  }

  private func report(_ progress: HeadlessUserDriver.Progress) {
    switch progress {
    case let .downloading(fraction):
      reportThrottledProgress("Downloading…", fraction: fraction)
    case let .extracting(fraction):
      reportThrottledProgress("Preparing…", fraction: fraction)
    case .installing:
      reportProgress("Installing…")
    }
  }

  private func failInstall(_ message: String) {
    Log.updates.error("install: failed: \(message, privacy: .public)")
    ServerLifecycleLog.default.error("update: install failed: \(message)")
    installSessionActive = false
    serverPreparedForUpdate = false
    installTargetBuild = nil
    updateLeaseHandoff?.cancel()
    updateLeaseHandoff = nil
    progressThrottle.reset()
    AppUpdateHandoff.enqueueStatus(state: "failed", message: message)
    model.reportFailure(message)
    Task { @MainActor [weak self] in
      await self?.localServer?.abandonAppUpdate()
    }
  }

  private static func otherRunningInstanceCount() -> Int {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return 0 }
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let ownBundle = Bundle.main.bundleURL.standardizedFileURL
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .filter { $0.processIdentifier != ownPid }
      .filter { $0.bundleURL?.standardizedFileURL == ownBundle }
      .count
  }

  private func displayedVersion(for item: SUAppcastItem) -> String {
    AppUpdateModel.displayedVersion(
      item.displayVersionString,
      buildNumber: Int(item.versionString),
      usesAlphaChannel: item.channel == "alpha"
    )
  }

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    model.allowsAlphaUpdates ? ["alpha"] : []
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    if let developmentFeedURL = CodevisorAppVariant.developmentSparkleFeedURL {
      return developmentFeedURL
    }
    return "https://updates.codevisor.dev/appcast-arm64.xml"
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    let version = displayedVersion(for: item)
    Log.updates.log(
      "check: found \(version, privacy: .public) (\(item.versionString, privacy: .public)), installing: \(self.installSessionActive)"
    )
    let releasePageURL = item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
    model.reportAvailable(version: version, releasePageURL: releasePageURL)
    if installSessionActive {
      installTargetBuild = Int(item.versionString)
      model.reportInstalling(version: version, releasePageURL: releasePageURL)
      reportProgress("Downloading…")
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    if installSessionActive {
      failInstall(
        "This machine's update feed has no newer release. Check its Alpha updates setting."
      )
      return
    }
    model.reportUpToDate()
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    let version = displayedVersion(for: item)
    Log.updates.log("install: Sparkle will install \(version, privacy: .public)")
    ServerLifecycleLog.default.note("update: installing \(version)")
    if installSessionActive {
      installTargetBuild = Int(item.versionString)
      AppUpdateHandoff.enqueueStatus(
        state: "installing",
        targetVersion: version,
        targetBuildNumber: installTargetBuild
      )
    }
    model.reportInstalling(
      version: version,
      releasePageURL: item.infoURL ?? item.fullReleaseNotesURL ?? item.releaseNotesURL
    )
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    if installSessionActive {
      failInstall(error.localizedDescription)
      return
    }
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
      self.reportProgress("Waiting for the server…")
      let prepared = await self.serverAgent.prepareForAppUpdate(localServer: self.localServer) {
        [weak self] status in
        self?.reportProgress(status)
      }
      guard prepared else {
        self.failInstall(
          "The Codevisor server could not be stopped safely. Restart Codevisor and try the update again."
        )
        return
      }
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
      self.reportProgress("Restarting…")
      await AppUpdateHandoff.flushWrites()
      Log.updates.log("install: server prepared; handing over to Sparkle for the relaunch")
      ServerLifecycleLog.default.note("update: server prepared, Sparkle relaunching the app")
      installHandler()
    }
    return true
  }
}
