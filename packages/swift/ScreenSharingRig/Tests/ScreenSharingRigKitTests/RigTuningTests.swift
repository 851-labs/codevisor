import CodevisorScreenSharing
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

  @Test(arguments: [
    #"{"profile":"fast"}"#, #"{"playoutDelayMs":[15,1]}"#, #"{"playoutDelayMs":[1]}"#, #"{"drawables":4}"#,
    #"{"offMainPreparation":true}"#, #"{"captureIntervalFPS":0}"#, #"{"jitterWindowFrames":1}"#, #"{"pacer":true}"#,
    #"{"renderOnArrival":"yes"}"#,
  ])
  func invalidTuningIsRefused(_ json: String) throws {
    let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(throws: (any Error).self) { try RigTuning.parse(object) }
  }
}
