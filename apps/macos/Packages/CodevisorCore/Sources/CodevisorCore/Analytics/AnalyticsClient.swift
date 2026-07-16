import Foundation
import PostHog

/// The complete event allowlist for product analytics. Keeping event names in
/// one closed enum lets the PostHog before-send hook reject every SDK/internal
/// event and makes accidental autocapture impossible to ship unnoticed.
public enum AnalyticsEventName: String, Sendable, CaseIterable {
    case appOpened = "app opened"
    case chatCreated = "chat created"
    case messageSent = "message sent"
    case modelSelected = "model selected"
    case harnessSelected = "harness selected"
    case turnCompleted = "turn completed"
    case turnFailed = "turn failed"
}

/// Analytics properties are deliberately scalar-only. There is no escape
/// hatch for arbitrary Encodable models, URLs, errors, or transcript objects,
/// which keeps prompts, responses, code, paths, and commands out by design.
public enum AnalyticsPropertyValue: Sendable, Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)

    fileprivate var postHogValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): value
        case let .double(value): value
        case let .boolean(value): value
        }
    }
}

/// Consent-gated, manual-only analytics for the macOS app.
///
/// Debug builds do not contact PostHog unless their scheme sets
/// `CODEVISOR_ENABLE_ANALYTICS=1`. Release builds configure lazily on the first
/// opt-in, so an opted-out launch performs no PostHog network work at all.
@MainActor
public final class AnalyticsClient {
    public static let shared = AnalyticsClient()

    private static let projectTokenKey = "CodevisorPostHogProjectToken"
    private static let hostKey = "CodevisorPostHogHost"
    private static let allowedEvents = Set(AnalyticsEventName.allCases.map(\.rawValue))

    private var projectToken: String?
    private var host: String?
    private var enabled = false
    private var sdkIsSetUp = false
    private var capturedAppOpen = false

    private init() {}

    /// Reads the public ingestion configuration embedded by the app target.
    /// The project token can submit events but cannot read or administer data.
    public func configureFromMainBundle(enabled: Bool) {
        guard projectToken == nil else {
            setEnabled(enabled)
            return
        }

        #if DEBUG
        guard ProcessInfo.processInfo.environment["CODEVISOR_ENABLE_ANALYTICS"] == "1" else {
            self.enabled = false
            return
        }
        #endif

        guard let token = Bundle.main.object(forInfoDictionaryKey: Self.projectTokenKey) as? String,
              !token.isEmpty,
              !token.hasPrefix("$("),
              let host = Bundle.main.object(forInfoDictionaryKey: Self.hostKey) as? String,
              URL(string: host) != nil else { return }

        projectToken = token
        self.host = host
        setEnabled(enabled)
    }

    /// Applies the app's persisted consent as the authoritative gate. Enabling
    /// lazily initializes PostHog; disabling stops all future capture calls.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard projectToken != nil else { return }

        if enabled {
            ensureSDKIsSetUp()
            PostHogSDK.shared.optIn()
            captureAppOpenedOnce()
        } else if sdkIsSetUp {
            PostHogSDK.shared.optOut()
        }
    }

    /// Records exactly one process launch, once consent and configuration are
    /// both present. Accepting during onboarding counts that current launch.
    public func captureAppOpenedOnce() {
        guard enabled, sdkIsSetUp, !capturedAppOpen else { return }
        capturedAppOpen = true
        capture(.appOpened)
    }

    public func capture(
        _ event: AnalyticsEventName,
        properties: [String: AnalyticsPropertyValue] = [:]
    ) {
        guard enabled, sdkIsSetUp else { return }
        var payload = commonProperties()
        for (key, value) in properties {
            payload[key] = value.postHogValue
        }
        PostHogSDK.shared.capture(event.rawValue, properties: payload)
    }

    private func ensureSDKIsSetUp() {
        guard !sdkIsSetUp, let projectToken, let host else { return }

        // Begin opted out even when the stored PostHog state says otherwise;
        // the app preference above remains the only source of consent.
        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.optOut = true
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.personProfiles = .never
        config.setDefaultPersonProperties = false
        let allowedEvents = Self.allowedEvents
        config.setBeforeSend { event in
            allowedEvents.contains(event.event) ? event : nil
        }
        PostHogSDK.shared.setup(config)
        sdkIsSetUp = true
    }

    private func commonProperties() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "app_version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "platform": "macos",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "arch": Self.architecture,
            "release_channel": Self.releaseChannel,
            // Do not derive or retain approximate location from the request IP.
            "$geoip_disable": true
        ]
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var releaseChannel: String {
        #if DEBUG
        "development"
        #else
        "release"
        #endif
    }
}

public extension AnalyticsClient {
    /// Coarse token ranges preserve useful cost/scale segmentation without
    /// transmitting exact conversation usage.
    static func tokenBucket(_ value: UInt64?) -> String? {
        guard let value else { return nil }
        return switch value {
        case 0: "0"
        case 1..<1_000: "1-999"
        case 1_000..<10_000: "1k-9.9k"
        case 10_000..<100_000: "10k-99.9k"
        default: "100k+"
        }
    }
}
