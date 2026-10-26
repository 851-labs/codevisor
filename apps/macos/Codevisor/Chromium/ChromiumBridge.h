#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void CVPrepareChromiumApplication(void);
FOUNDATION_EXPORT void CVShutdownChromium(void (^completion)(void));
FOUNDATION_EXPORT BOOL CVChromiumIsPumping(void);

typedef NS_ENUM(NSInteger, CVChromiumDownloadState) {
  CVChromiumDownloadStateInProgress,
  CVChromiumDownloadStateComplete,
  CVChromiumDownloadStateCanceled,
  CVChromiumDownloadStateFailed,
};

@interface CVChromiumDownload : NSObject
@property(nonatomic, readonly) uint32_t identifier;
@property(nonatomic, readonly, copy) NSString *path;
@property(nonatomic, readonly) int64_t receivedBytes;
@property(nonatomic, readonly) int64_t totalBytes;
@property(nonatomic, readonly) CVChromiumDownloadState state;
@end

FOUNDATION_EXPORT void CVObserveChromiumDownloads(void (^ _Nullable observer)(CVChromiumDownload *download));
FOUNDATION_EXPORT void CVCancelChromiumDownload(uint32_t identifier);

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
@property(nonatomic, copy, nullable) void (^browserClosed)(BOOL closedByPage);
@property(nonatomic, copy, nullable) void (^stateChanged)(NSString *url, NSString *title, BOOL loading, BOOL back, BOOL forward);
@property(nonatomic, copy, nullable) void (^zoomChanged)(NSInteger percent, BOOL canZoomOut, BOOL canZoomIn, BOOL canReset);
@property(nonatomic, copy, nullable) void (^browserReady)(void);
@property(nonatomic, copy, nullable) void (^faviconChanged)(NSData * _Nullable image);
@property(nonatomic, copy, nullable) void (^viewportScaleChanged)(CGFloat scale);
@property(nonatomic, copy, nullable) void (^protocolEvent)(NSData *message);
@property(nonatomic, copy, nullable) void (^findResult)(NSInteger matches, NSInteger activeMatch, BOOL finished);
@property(nonatomic, copy, nullable) void (^proxyCredentialsRejected)(NSString *username, NSString *password, void (^reply)(NSString * _Nullable username, NSString * _Nullable password));
- (void)sendProtocolMethod:(NSString *)method
                    params:(nullable NSData *)params
                 sessionId:(nullable NSString *)sessionId
                completion:(void (^)(NSData *reply))completion NS_SWIFT_DISABLE_ASYNC;
@property(nonatomic, readonly) BOOL browserIsReady;
@property(nonatomic, readonly) BOOL hasCommittedPage;
@property(nonatomic, readonly) BOOL hasOpenDevTools;
@property(nonatomic, readonly) BOOL hasPageFocus;
@property(nonatomic, copy, nullable) void (^loadFailed)(NSInteger code, NSString *message, NSString *url);
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
- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding;
- (void)showDevTools;
- (void)closeBrowser;
@end
NS_ASSUME_NONNULL_END
