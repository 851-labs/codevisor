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
@property(nonatomic, copy, nullable) void (^zoomChanged)(NSInteger percent, BOOL canZoomOut, BOOL canZoomIn, BOOL canReset);
@property(nonatomic, copy, nullable) void (^browserReady)(void);
@property(nonatomic, copy, nullable) void (^faviconChanged)(NSData * _Nullable image);
@property(nonatomic, copy, nullable) void (^viewportScaleChanged)(CGFloat scale);
/// Receives every DevTools protocol event of this page as raw JSON bytes, in
/// arrival order, on the CEF UI (main) thread. Hand the bytes off; parse elsewhere.
@property(nonatomic, copy, nullable) void (^protocolEvent)(NSData *message);
/// Sends one protocol command without parsing it. `params` must be the JSON
/// bytes of an object. `completion` receives the raw reply exactly once on the
/// CEF UI (main) thread, in order with `protocolEvent`, possibly before this
/// method returns; it must only hand the bytes off.
- (void)sendProtocolMethod:(NSString *)method
                    params:(nullable NSData *)params
                 sessionId:(nullable NSString *)sessionId
                completion:(void (^)(NSData *reply))completion NS_SWIFT_DISABLE_ASYNC;
@property(nonatomic, readonly) BOOL browserIsReady;
@property(nonatomic, readonly) BOOL hasOpenDevTools;
@property(nonatomic, readonly) BOOL hasPageFocus;
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
- (void)reloadIgnoringCache;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (void)stop;
- (void)goBack;
- (void)goForward;
- (void)focusPage;
- (void)showDevTools;
- (void)closeBrowser;
@end
NS_ASSUME_NONNULL_END
