#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs `trials` as WebRTC's process-wide field trials. Must run before any RTC object exists;
/// `ScreenSharingFieldTrials` is the only caller and enforces that.
void CodevisorInstallWebRTCProcessFieldTrials(NSDictionary<NSString *, NSString *> *trials);

NS_ASSUME_NONNULL_END
