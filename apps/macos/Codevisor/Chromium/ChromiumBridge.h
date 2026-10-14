#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void CVPrepareChromiumApplication(void);
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
@property(nonatomic, copy, nullable) BOOL (^adoptPopup)(CVChromiumView *popup, NSString *url, CVBrowserLinkDestination destination);
@property(nonatomic, copy, nullable) void (^pageClosed)(void);
@property(nonatomic, copy, nullable) void (^stateChanged)(NSString *url, NSString *title, BOOL loading, BOOL back, BOOL forward);
@property(nonatomic, copy, nullable) void (^zoomChanged)(NSInteger percent, BOOL canZoomOut, BOOL canZoomIn, BOOL canReset);
@property(nonatomic, copy, nullable) void (^browserReady)(void);
@property(nonatomic, copy, nullable) void (^faviconChanged)(NSData * _Nullable image);
@property(nonatomic, copy, nullable) void (^viewportScaleChanged)(CGFloat scale);
@property(nonatomic, copy, nullable) void (^protocolEvent)(NSData *message);
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
