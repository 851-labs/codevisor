import ScreenSharing
import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigTuningTests {
  @Test func defaultsInstallNoTrialsAndKeepTheProductRenderer() throws {
    let tuning = try RigTuning.parse([:])
    #expect(tuning == .default)
    #expect(tuning.fieldTrialSelection == .default)
    #expect(tuning.label == nil)
    let configuration = try RigConfiguration.parse(
      RigConfigurationTests.json(["role": "host", "token": RigConfigurationTests.token]))
    #expect(configuration.tuning == .default)
  }

  @Test func profileSetsABaseThatKeysOverride() throws {
    let tuning = try RigTuning.parse(["profile": "paced15-worker", "drawables": 3, "captureIntervalFPS": 90])
    #expect(tuning.playoutDelayMs?.min == 1 && tuning.playoutDelayMs?.max == 15)
    #expect(tuning.renderOnArrival && tuning.offMainPreparation)
    #expect(tuning.maximumDrawableCount == 3)
    #expect(tuning.captureIntervalFPS == 90)
    #expect(tuning.fieldTrialSelection.trials == ["WebRTC-ForcePlayoutDelay": "min_ms:1,max_ms:15"])
    #expect(tuning.label == "playout 1/15 · arrival+worker · capture 90")
    #expect(
      tuning.fieldTrialSelection.trials["WebRTC-ForcePlayoutDelay"]
        == ScreenSharingDiagnosticProfile.paced15Worker.fieldTrials["WebRTC-ForcePlayoutDelay"],
      "the rig spells the trial exactly as the product profile does")
  }

  @Test func explicitKnobsMapToTrials() throws {
    let tuning = try RigTuning.parse(["playoutDelayMs": [0, 35], "jitterWindowFrames": 30, "renderOnArrival": true])
    #expect(
      tuning.fieldTrialSelection.trials == [
        "WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:35",
        "WebRTC-JitterEstimatorConfig": "max_frame_size_percentile:0.95,frame_size_window:30",
      ])
    #expect(tuning.label == "playout 0/35 · jitter window 30 · arrival")
  }

  @Test func encoderAndTransportKnobsParseAndLabel() throws {
    let tuning = try RigTuning.parse([
      "keyframeIntervalSeconds": 60, "rateControl": "standard", "pendingFrames": 3, "transportCeiling": 75_000_000,
      "staticCodecRate": true, "pacingFactor": 10,
    ])
    #expect(tuning.keyframeIntervalSeconds == 60)
    #expect(tuning.standardRateControl)
    #expect(tuning.pendingFrames == 3)
    #expect(tuning.transportCeilingBps == 75_000_000)
    #expect(tuning.staticCodecRate)
    #expect(tuning.pacingFactor == 10)
    #expect(tuning.fieldTrialSelection.trials == ["WebRTC-Video-Pacing": "factor:10.0"], "only pacing is a trial")
    #expect(tuning.label == "keyframe 60s · standard rc · pending 3 · ceiling 75 Mb · static rate · pacing ×10.0")
    let lowLatency = try RigTuning.parse(["rateControl": "lowLatency"])
    #expect(lowLatency == .default)
    let one = try #require(try JSONSerialization.jsonObject(with: Data(#"{"pendingFrames":1}"#.utf8)) as? [String: Any])
    #expect(try RigTuning.parse(one).pendingFrames == 1, "JSON 1 is an integer, not a boolean")
    let zero = try #require(
      try JSONSerialization.jsonObject(with: Data(#"{"staticCodecRate":0}"#.utf8)) as? [String: Any])
    #expect(throws: (any Error).self) { try RigTuning.parse(zero) }
  }

  @Test(arguments: [
    #"{"profile":"fast"}"#, #"{"playoutDelayMs":[15,1]}"#, #"{"playoutDelayMs":[1]}"#, #"{"drawables":4}"#,
    #"{"offMainPreparation":true}"#, #"{"captureIntervalFPS":0}"#, #"{"jitterWindowFrames":1}"#, #"{"pacer":true}"#,
    #"{"renderOnArrival":"yes"}"#, #"{"keyframeIntervalSeconds":0}"#, #"{"keyframeIntervalSeconds":61}"#,
    #"{"rateControl":"cbr"}"#, #"{"pendingFrames":9}"#, #"{"transportCeiling":1000}"#,
    #"{"transportCeiling":"75M"}"#, #"{"staticCodecRate":"yes"}"#, #"{"renderOnArrival":1}"#, #"{"pacingFactor":0.5}"#,
    #"{"pacingFactor":true}"#,
  ])
  func invalidTuningIsRefused(_ json: String) throws {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(throws: (any Error).self) { try RigTuning.parse(object) }
  }
}
