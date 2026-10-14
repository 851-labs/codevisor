#import "WebRTCProcessFieldTrials.h"

#import <WebRTC/RTCFieldTrials.h>

void CodevisorInstallWebRTCProcessFieldTrials(NSDictionary<NSString *, NSString *> *trials) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  RTCInitFieldTrialDictionary(trials);
#pragma clang diagnostic pop
}
