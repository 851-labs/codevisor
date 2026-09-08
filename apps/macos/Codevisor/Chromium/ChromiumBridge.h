#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Must run before SwiftUI creates NSApplication.
FOUNDATION_EXPORT void CVPrepareChromiumApplication(void);
/// Closes every browser and calls CEF shutdown before completing on the main thread.
FOUNDATION_EXPORT void CVShutdownChromium(void (^completion)(void));

typedef NS_ENUM(NSInteger, CVBrowserLinkDestination) {
  CVBrowserLinkDestinationBackgroundTab,
  CVBrowserLinkDestinationForegroundTab,
  CVBrowserLinkDestinationWindow,
  CVBrowserLinkDestinationSplitRight,
  CVBrowserLinkDestinationSplitLeft,
  CVBrowserLinkDestinationSplitAbove,
  CVBrowserLinkDestinationSplitBelow,
};

@interface CVChromiumView : NSView
@property(nonatomic, copy, nullable) BOOL (^openLink)(NSString *url, CVBrowserLinkDestination destination);
/// Adopt CEF's real popup rather than replaying its URL (preserves POST/opener).
@property(nonatomic, copy, nullable) BOOL (^adoptPopup)(CVChromiumView *popup, NSString *url, CVBrowserLinkDestination destination);
@property(nonatomic, copy, nullable) void (^pageClosed)(void);
@property(nonatomic, copy, nullable) void (^stateChanged)(NSString *url, NSString *title, BOOL loading, BOOL back, BOOL forward);
@property(nonatomic, copy, nullable) void (^browserReady)(void);
@property(nonatomic, copy, nullable) void (^faviconChanged)(NSData * _Nullable image);
@property(nonatomic, copy, nullable) void (^viewportScaleChanged)(CGFloat scale);
@property(nonatomic, copy, nullable) void (^protocolEvent)(NSString *json);
- (void)sendProtocol:(NSString *)json completion:(void (^)(NSString *reply))completion;
@property(nonatomic, readonly) BOOL browserIsReady;
@property(nonatomic, readonly) BOOL hasOpenDevTools;
@property(nonatomic, copy, nullable) void (^loadFailed)(NSString *message);
- (instancetype)initWithProfile:(NSString *)profile
                     proxyHost:(NSString *)host
                     proxyPort:(NSInteger)port
                      proxyTLS:(BOOL)tls
                      username:(NSString *)username
                      password:(NSString *)password
                       address:(NSString *)address;
- (void)navigate:(NSString *)address;
- (CGFloat)setViewportWidth:(CGFloat)width height:(CGFloat)height;
- (void)reload;
- (void)stop;
- (void)goBack;
- (void)goForward;
- (void)focusPage;
- (void)showDevTools;
- (void)closeBrowser;
@end
NS_ASSUME_NONNULL_END
