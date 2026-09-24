#import "WebRTCProcessFieldTrials.h"

#import <WebRTC/RTCFieldTrials.h>

void CodevisorInstallWebRTCProcessFieldTrials(NSDictionary<NSString *, NSString *> *trials) {
  // `RTCInitFieldTrialDictionary` is deprecated in favour of passing field trials when building the
  // factory, but at the pinned WebRTC (152.0.0-codevisor.1) that replacement exists only as the
  // Objective-C++ `RTCPeerConnectionFactoryBuilder -setFieldTrials:(std::unique_ptr<FieldTrialsView>)`,
  // which the binary framework does not export in its public headers. Until the fork exposes a
  // Swift-callable factory initializer taking field trials, this is the only public entry point, so
  // the deprecation is silenced for this one call and nowhere else.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  RTCInitFieldTrialDictionary(trials);
#pragma clang diagnostic pop
}
