#import "ChromiumBridge.h"
#import "ChromiumFavicon.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_resource_bundle.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_helpers.h"
#include <map>
#include <functional>
#include <vector>
#include <set>
#include <optional>
#include <cmath>

@interface CVChromiumApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation CVChromiumApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEvent;
  [super sendEvent:event];
}
@end

void CVPrepareChromiumApplication(void) {
  [CVChromiumApplication sharedApplication];
  NSCAssert([NSApp isKindOfClass:CVChromiumApplication.class], @"CEF requires its NSApplication event adapter");
}

namespace {
bool initialized = false;
bool shuttingDown = false;
bool pumping = false;
NSTimer *pumpTimer;
void (^shutdownCompletion)(void);
std::map<int, CefRefPtr<CefBrowser>> browsers;
NSHashTable<CVChromiumView *> *zoomViews;
std::unique_ptr<CefScopedLibraryLoader> library;

void SchedulePump(int64_t delay);
void Pump() {
  if (!initialized || shuttingDown || pumping) return;
  pumping = true;
  CefDoMessageLoopWork();
  pumping = false;
  // CEF's external-pump example uses this bounded fallback for delayed work.
  if (!pumpTimer) SchedulePump(33);
}
void SchedulePump(int64_t delay) {
  [pumpTimer invalidate];
  pumpTimer = nil;
  if (!initialized || shuttingDown) return;
  pumpTimer = [NSTimer timerWithTimeInterval:MAX(0, MIN(delay, 33)) / 1000.0
                                   repeats:NO block:^(NSTimer *timer) {
    pumpTimer = nil;
    Pump();
  }];
  [NSRunLoop.mainRunLoop addTimer:pumpTimer forMode:NSRunLoopCommonModes];
}
class Application final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    // CEF otherwise shows Chrome's login dialog instead of invoking its public
    // GetAuthCredentials callback, including for the workspace proxy capability.
    command->AppendSwitch("disable-chrome-login-prompt");
    command->AppendSwitch("disable-quic");
  }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    dispatch_async(dispatch_get_main_queue(), ^{ SchedulePump(delay); });
  }
 private:
  IMPLEMENT_REFCOUNTING(Application);
};
NSString *String(const CefString& value) { return [NSString stringWithUTF8String:value.ToString().c_str()] ?: @""; }
CefString String(NSString *value) { return CefString(value.UTF8String ?: ""); }

bool Initialize() {
  if (initialized) return !shuttingDown;
  if (shuttingDown) return false;
  library = std::make_unique<CefScopedLibraryLoader>();
  if (!library->LoadInMain()) return false;
  CefSettings settings;
  settings.external_message_pump = true;
  settings.log_severity = LOGSEVERITY_WARNING;
  NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  // Fresh profiles accompany the app-owned Keychain item. Do not try to
  // decrypt old profiles with the new key or request Chromium's shared key.
  NSString *root = [[support stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier] stringByAppendingPathComponent:@"Chromium-v2"];
  CefString(&settings.root_cache_path) = String(root);
  CefString(&settings.log_file) = String([root stringByAppendingPathComponent:@"chromium.log"]);
  NSString *appName = NSBundle.mainBundle.executablePath.lastPathComponent;
  NSString *helperName = [appName stringByReplacingOccurrencesOfString:@"Codevisor" withString:@"Codevisor Browser Helper"
                                                              options:NSAnchoredSearch range:NSMakeRange(0, appName.length)];
  NSString *helperBundle = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:[helperName stringByAppendingString:@".app"]];
  NSString *helper = [NSBundle bundleWithPath:helperBundle].executablePath;
  if (!helper) return false;
  CefString(&settings.browser_subprocess_path) = String(helper);
  std::vector<std::string> arguments;
  for (NSString *argument in NSProcessInfo.processInfo.arguments) arguments.emplace_back(argument.UTF8String);
  std::vector<char *> argv;
  for (auto& argument : arguments) argv.push_back(argument.data());
  CefMainArgs args((int)argv.size(), argv.data());
  initialized = CefInitialize(args, settings, new Application(), nullptr);
  if (initialized) SchedulePump(0);
  return initialized;
}
void FinishShutdownIfReady() {
  if (!shutdownCompletion || !browsers.empty()) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!shutdownCompletion || !browsers.empty()) return;
    shuttingDown = true;
    [pumpTimer invalidate]; pumpTimer = nil;
    if (initialized) CefShutdown();
    initialized = false;
    // Keep the framework loaded until process exit; AppKit may still unwind CEF frames.
    auto completion = shutdownCompletion;
    shutdownCompletion = nil;
    completion();
  });
}
}

void CVShutdownChromium(void (^completion)(void)) {
  if (!initialized) { completion(); return; }
  shutdownCompletion = [completion copy];
  auto open = browsers;
  for (const auto& entry : open) entry.second->GetHost()->CloseBrowser(true);
  FinishShutdownIfReady();
}

class ProtocolObserver;
class BrowserClient;
class DevToolsClient;
@interface CVChromiumView () <NSWindowDelegate, NSSplitViewDelegate> {
 @public
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<ProtocolObserver> _protocolObserver;
  CefRefPtr<CefRegistration> _protocolRegistration;
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<BrowserClient> _client;
  CefRefPtr<CefBrowser> _toolsBrowser;
  CefRefPtr<DevToolsClient> _toolsClient;
  NSSplitView *_splitView;
  NSView *_pageContainer;
  NSView *_viewportHost;
  CGFloat _viewportScale;
  NSView *_toolsContainer;
  NSWindow *_toolsWindow;
  NSString *_toolsDockSide;
  BOOL _toolsCreating;
  BOOL _toolsCloseRequested;
  BOOL _toolsFrontendReady;
  BOOL _layingOutTools;
  int _pendingInspection;
  CGFloat _viewportWidth;
  CGFloat _viewportHeight;
  CGFloat _pageFraction;
  CGFloat _pageHeightFraction;
  BOOL _started;
  BOOL _contextReady;
  BOOL _creating;
  BOOL _closed;
  NSUInteger _faviconGeneration;
  BOOL _faviconRequested;
  NSString *_address;
  NSString *_profile;
  NSString *_proxyHost;
  NSInteger _proxyPort;
  BOOL _proxyTLS;
  NSString *_username;
  NSString *_password;
  NSWindow *_popupWindow;
}
- (void)layoutViewport;
- (void)createBrowser;
- (void)publish;
- (void)publishZoom;
- (void)zoom:(cef_zoom_command_t)command;
- (void)closeDevTools;
- (void)removeDevTools;
- (void)setDevToolsDockSide:(NSString *)side;
- (void)focusDevTools;
- (void)inspectPendingNode;
@end

namespace {
const char* devToolsOrigin = "https://devtools.codevisor.invalid/";
bool IsDevToolsResource(const CefString& url) { return url.ToString().starts_with(devToolsOrigin); }
bool IsDevToolsDockSide(NSString *side) { return [@[@"right", @"left", @"bottom", @"undocked"] containsObject:side]; }

// This handler is installed only on the privileged frontend browser. Ordinary
// web pages cannot load this origin or obtain its native debugging bindings.
class DevToolsResource final : public CefResourceHandler {
 public:
  explicit DevToolsResource(NSString *path) {
    static NSDictionary *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      NSData *json = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"Chromium-DevTools-resources" withExtension:@"json"]];
      if (json) index = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    });
    if ([path isEqualToString:@"/codevisor.js"]) {
      data_ = [NSData dataWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"Chromium-DevTools" withExtension:@"js"]];
    } else {
      if ([path isEqualToString:@"/"]) path = @"/devtools_app.html";
      NSString *key = [[path substringFromIndex:1] uppercaseString];
      key = [[key componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@"_"];
      NSNumber *resourceID = index[key];
      if (resourceID) {
        auto resource = CefResourceBundle::GetGlobal()->GetDataResource(resourceID.intValue);
        if (resource) {
          NSMutableData *data = [NSMutableData dataWithLength:resource->GetSize()];
          resource->GetData(data.mutableBytes, data.length, 0);
          data_ = data;
        }
      }
      if ([path isEqualToString:@"/devtools_app.html"] && data_) {
        NSString *html = [[NSString alloc] initWithData:data_ encoding:NSUTF8StringEncoding];
        data_ = [[html stringByReplacingOccurrencesOfString:@"entrypoints/devtools_app/devtools_app.js" withString:@"codevisor.js"] dataUsingEncoding:NSUTF8StringEncoding];
      }
    }
    mime_ = @{@"html": @"text/html", @"js": @"text/javascript", @"css": @"text/css", @"json": @"application/json",
              @"svg": @"image/svg+xml", @"png": @"image/png", @"jpg": @"image/jpeg", @"avif": @"image/avif",
              @"webp": @"image/webp", @"woff2": @"font/woff2", @"wasm": @"application/wasm"}[path.pathExtension] ?: @"application/octet-stream";
  }
  bool Open(CefRefPtr<CefRequest>, bool& handle, CefRefPtr<CefCallback>) override { handle = true; return true; }
  void GetResponseHeaders(CefRefPtr<CefResponse> response, int64_t& length, CefString&) override {
    response->SetStatus(data_ ? 200 : 404);
    response->SetMimeType(String(mime_));
    response->SetHeaderByName("X-Content-Type-Options", "nosniff", true);
    response->SetHeaderByName("Content-Security-Policy", "frame-ancestors 'none'", true);
    length = data_.length;
  }
  bool Read(void* output, int count, int& read, CefRefPtr<CefResourceReadCallback>) override {
    read = (int)MIN((NSUInteger)count, data_.length - offset_);
    if (read) { memcpy(output, (const char*)data_.bytes + offset_, read); offset_ += read; }
    return read > 0;
  }
  void Cancel() override {}
 private:
  NSData *data_;
  NSString *mime_;
  NSUInteger offset_ = 0;
  IMPLEMENT_REFCOUNTING(DevToolsResource);
};
}

class DevToolsClient final : public CefClient, public CefLifeSpanHandler, public CefDisplayHandler,
                             public CefRequestHandler, public CefResourceRequestHandler,
                             public CefDevToolsMessageObserver {
 public:
  explicit DevToolsClient(CVChromiumView *view) : view_(view) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browsers[browser->GetIdentifier()] = browser;
    CVChromiumView *view = view_;
    if (view) view->_toolsCreating = NO;
    if (!view || view->_closed || view->_toolsCloseRequested || !view->_toolsContainer || shutdownCompletion) { browser->GetHost()->CloseBrowser(true); return; }
    view->_toolsBrowser = browser;
    registration_ = view->_browser->GetHost()->AddDevToolsMessageObserver(this);
    // Own a CDP session so closing this frontend detaches debugger/emulation
    // state, including paused execution and auto-attached workers.
    targetInfoRequest_ = view->_browser->GetHost()->ExecuteDevToolsMethod(0, "Target.getTargetInfo", nullptr);
    browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    child.frame = view->_toolsContainer.bounds;
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    CVChromiumView *view = view_;
    if (view) view->_toolsWindow.title = String(title);
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [child removeFromSuperview]; });
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    closed_ = true;
    CVChromiumView *view = view_;
    // If attachment is still in flight, retain the observer until its reply
    // arrives so that the newly created session can also be detached.
    if (!attachRequest_ || !session_.empty()) Detach(view ? view->_browser : nullptr);
    if (view) {
      view->_toolsBrowser = nullptr;
      view->_toolsClient = nullptr;
      [view removeDevTools];
    }
    browsers.erase(browser->GetIdentifier());
    FinishShutdownIfReady();
  }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
      CefRefPtr<CefRequest> request, bool, bool, const CefString&, bool& disableDefault) override {
    if (!IsDevToolsResource(request->GetURL())) return nullptr;
    disableDefault = true;
    return this;
  }
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request) override {
    if (!IsDevToolsResource(request->GetURL())) return nullptr;
    return new DevToolsResource([NSURL URLWithString:String(request->GetURL())].path);
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request, bool, bool) override {
    return !IsDevToolsResource(request->GetURL());
  }
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> target, const void* bytes, size_t length) override {
    auto value = CefParseJSON(bytes, length, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return true;
    auto data = value->GetDictionary();
    if (!data->HasKey("sessionId")) {
      // Browser-domain replies can arrive inside ExecuteDevToolsMethod. Defer
      // handling until it returns the assigned request ID.
      CefRefPtr<DevToolsClient> client = this;
      dispatch_async(dispatch_get_main_queue(), ^{ client->HandleControlReply(target, value); });
      return true;
    }
    CVChromiumView *view = view_;
    if (closed_ || !view || !view->_toolsBrowser || view->_closed) return true;
    auto session = data->GetString("sessionId").ToString();
    if (session != session_ && !childSessions_.contains(session)) return true;
    auto method = data->GetString("method");
    auto params = data->GetDictionary("params");
    if (params && method == "Target.attachedToTarget") childSessions_.insert(params->GetString("sessionId").ToString());
    if (params && method == "Target.detachedFromTarget") childSessions_.erase(params->GetString("sessionId").ToString());
    if (session == session_) data->Remove("sessionId");
    auto message = CefProcessMessage::Create("CodevisorDevTools.message");
    message->GetArgumentList()->SetString(0, CefWriteJSON(value, JSON_WRITER_DEFAULT));
    view->_toolsBrowser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
    return true;
  }
  void HandleControlReply(CefRefPtr<CefBrowser> target, CefRefPtr<CefValue> value) {
    auto data = value->GetDictionary();
    int identifier = data->GetInt("id");
    auto result = data->GetDictionary("result");
    if (identifier == targetInfoRequest_ && result) {
      if (closed_ || !target->IsValid()) { Detach(target); return; }
      auto info = result->GetDictionary("targetInfo");
      if (info) {
        auto params = CefDictionaryValue::Create();
        params->SetString("targetId", info->GetString("targetId"));
        params->SetBool("flatten", true);
        attachRequest_ = target->GetHost()->ExecuteDevToolsMethod(0, "Target.attachToTarget", params);
      }
    } else if (identifier == attachRequest_ && result) {
      session_ = result->GetString("sessionId");
      if (closed_) { Detach(target); return; }
      for (const auto& pending : pending_) Send(pending);
      pending_.clear();
    } else if ((identifier == targetInfoRequest_ || identifier == attachRequest_) && data->HasKey("error")) {
      NSLog(@"Codevisor DevTools could not attach: %@", String(CefWriteJSON(value, JSON_WRITER_DEFAULT)));
      Detach(target);
    }
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override {
    session_.clear();
    registration_ = nullptr;
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    CVChromiumView *view = view_;
    if (!view || view->_closed || source != PID_RENDERER || !frame->IsMain() || !IsDevToolsResource(frame->GetURL()) ||
        !view->_toolsBrowser || browser->GetIdentifier() != view->_toolsBrowser->GetIdentifier()) return false;
    auto name = message->GetName().ToString();
    if (!name.starts_with("CodevisorDevTools.")) return false;
    auto argument = message->GetArgumentList()->GetString(0);
    if (name == "CodevisorDevTools.send" && view->_browser) {
      if (session_.empty()) pending_.push_back(argument.ToString());
      else Send(argument.ToString());
    } else if (name == "CodevisorDevTools.close") {
      [view closeDevTools];
    } else if (name == "CodevisorDevTools.dock") {
      auto value = CefParseJSON(argument, JSON_PARSER_RFC);
      if (!value || value->GetType() != VTYPE_DICTIONARY) return true;
      auto data = value->GetDictionary();
      NSString *side = String(data->GetString("side"));
      if (!IsDevToolsDockSide(side) || view->_toolsCloseRequested) return true;
      [view setDevToolsDockSide:side];
      auto reply = CefProcessMessage::Create("CodevisorDevTools.docked");
      reply->GetArgumentList()->SetInt(0, data->GetInt("request"));
      frame->SendProcessMessage(PID_RENDERER, reply);
    } else if (name == "CodevisorDevTools.focus") {
      [view focusDevTools];
    } else if (name == "CodevisorDevTools.ready") {
      view->_toolsFrontendReady = YES;
      [view inspectPendingNode];
    } else if (name == "CodevisorDevTools.copy") {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:String(argument) forType:NSPasteboardTypeString];
    } else if (name == "CodevisorDevTools.open") {
      NSURL *url = [NSURL URLWithString:String(argument)];
      if ([@[@"http", @"https"] containsObject:url.scheme]) [view navigate:url.absoluteString];
    }
    return true;
  }
 private:
  void Detach(CefRefPtr<CefBrowser> target) {
    registration_ = nullptr;
    if (target && target->IsValid() && !session_.empty()) {
      auto params = CefDictionaryValue::Create();
      params->SetString("sessionId", session_);
      session_.clear();
      target->GetHost()->ExecuteDevToolsMethod(0, "Target.detachFromTarget", params);
    }
    pending_.clear();
    childSessions_.clear();
  }
  void Send(const std::string& input) {
    CVChromiumView *view = view_;
    if (!view || !view->_browser || view->_closed) return;
    auto value = CefParseJSON(input, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return;
    auto data = value->GetDictionary();
    if (!data->HasKey("sessionId")) data->SetString("sessionId", session_);
    else if (!childSessions_.contains(data->GetString("sessionId").ToString())) return;
    auto message = CefWriteJSON(value, JSON_WRITER_DEFAULT).ToString();
    view->_browser->GetHost()->SendDevToolsMessage(message.data(), message.size());
  }
  __weak CVChromiumView *view_;
  CefRefPtr<CefRegistration> registration_;
  bool closed_ = false;
  int targetInfoRequest_ = 0;
  int attachRequest_ = 0;
  std::string session_;
  std::set<std::string> childSessions_;
  std::vector<std::string> pending_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

// Resolve the context-menu location before docking changes the page's viewport.
// Backend node IDs survive the resize and can be revealed in the frontend's
// own protocol session after it has initialized.
class ContextInspection final : public CefDevToolsMessageObserver {
 public:
  explicit ContextInspection(CVChromiumView *view) : view_(view) {}
  void Start(CefRefPtr<CefBrowser> browser, int x, int y) {
    registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    auto params = CefDictionaryValue::Create();
    params->SetInt("x", x);
    params->SetInt("y", y);
    params->SetBool("includeUserAgentShadowDOM", true);
    request_ = browser->GetHost()->ExecuteDevToolsMethod(0, "DOM.getNodeForLocation", params);
    if (!request_) Complete(nullptr);
  }
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void *bytes, size_t length) override {
    auto value = CefParseJSON(bytes, length, JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) return true;
    auto data = value->GetDictionary();
    if (!data->HasKey("id") || data->HasKey("sessionId")) return true;
    CefRefPtr<ContextInspection> inspection = this;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (data->GetInt("id") == inspection->request_) inspection->Complete(data->GetDictionary("result"));
    });
    return true;
  }
  void OnDevToolsAgentDetached(CefRefPtr<CefBrowser>) override { registration_ = nullptr; }
 private:
  void Complete(CefRefPtr<CefDictionaryValue> result) {
    registration_ = nullptr;
    CVChromiumView *view = view_;
    if (!view || view->_closed) return;
    view->_pendingInspection = result ? result->GetInt("backendNodeId") : 0;
    [view showDevTools];
    [view inspectPendingNode];
  }
  __weak CVChromiumView *view_;
  CefRefPtr<CefRegistration> registration_;
  int request_ = 0;
  IMPLEMENT_REFCOUNTING(ContextInspection);
};

// Each caller gets a distinct request id. DevTools and automation can attach
// independent CDP sessions without consuming each other's replies.
class ProtocolObserver final : public CefDevToolsMessageObserver {
 public:
  explicit ProtocolObserver(CVChromiumView *view) : view_(view) {}
  std::map<int, void (^)(NSString *)> pending;
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void *bytes, size_t length) override {
    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSNumber *number = message[@"id"];
    if (number) {
      auto found = pending.find(number.intValue);
      if (found != pending.end()) {
        auto callback = found->second;
        pending.erase(found);
        NSString *reply = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{ callback(reply); });
      }
    } else if (view_.protocolEvent) {
      NSString *event = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      view_.protocolEvent(event);
    }
    return true;
  }
  void Close() {
    auto callbacks = std::move(pending);
    for (auto& entry : callbacks) entry.second(@"{\"error\":{\"message\":\"Browser closed\"}}");
  }
 private:
  __weak CVChromiumView *view_;
  IMPLEMENT_REFCOUNTING(ProtocolObserver);
};

class ContextHandler final : public CefRequestContextHandler {
 public:
  explicit ContextHandler(CVChromiumView *view) : view_(view) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    CVChromiumView *view = view_;
    if (!view || view->_closed) return;
    auto proxy = CefDictionaryValue::Create();
    proxy->SetString("mode", "fixed_servers");
    NSString *host = view->_proxyHost;
    if ([host containsString:@":"] && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
    proxy->SetString("server", String([NSString stringWithFormat:@"%@://%@:%ld", view->_proxyTLS ? @"https" : @"http", host, (long)view->_proxyPort]));
    // Chromium otherwise implicitly sends localhost directly to the client machine.
    proxy->SetString("bypass_list", "<-loopback>");
    auto value = CefValue::Create(); value->SetDictionary(proxy);
    CefString error;
    if (!context->SetPreference("proxy", value, error)) {
      if (view.loadFailed) view.loadFailed(@"Couldn’t configure the workspace proxy.");
      return;
    }
    auto rtcPolicy = CefValue::Create();
    rtcPolicy->SetString("disable_non_proxied_udp");
    if (!context->SetPreference("webrtc.ip_handling_policy", rtcPolicy, error)) {
      if (view.loadFailed) view.loadFailed(@"Couldn’t configure browser network isolation.");
      return;
    }
    view->_contextReady = YES;
    [view createBrowser];
  }
 private:
  __weak CVChromiumView *view_;
  IMPLEMENT_REFCOUNTING(ContextHandler);
};

namespace {
enum LinkMenuCommand {
  InspectPage = MENU_ID_USER_FIRST,
  OpenLinkTab, OpenLinkWindow, OpenLinkSplit, CopyLinkAddress,
};
std::optional<CVBrowserLinkDestination> LinkDestination(cef_window_open_disposition_t disposition) {
  switch (disposition) {
    case CEF_WOD_NEW_BACKGROUND_TAB: return CVBrowserLinkDestinationBackgroundTab;
    case CEF_WOD_NEW_FOREGROUND_TAB: return CVBrowserLinkDestinationForegroundTab;
    case CEF_WOD_NEW_WINDOW: return CVBrowserLinkDestinationWindow;
    default: return std::nullopt;
  }
}
bool IsWebLink(NSString *address) {
  return [@[@"http", @"https"] containsObject:[NSURL URLWithString:address].scheme.lowercaseString];
}
}

class BrowserClient final : public CefClient, public CefLifeSpanHandler,
                            public CefDisplayHandler, public CefLoadHandler,
                            public CefRequestHandler, public CefContextMenuHandler {
 public:
  explicit BrowserClient(CVChromiumView *view) : view_(view), host_(view->_proxyHost.UTF8String ?: ""),
      port_((int)view->_proxyPort), username_(view->_username.UTF8String ?: ""), password_(view->_password.UTF8String ?: "") {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> menu) override {
    if (!params->GetLinkUrl().empty()) {
      int index = 0;
      if (view_.openLink && IsWebLink(String(params->GetLinkUrl()))) {
        menu->InsertItemAt(index++, OpenLinkTab, "Open Link in New Tab");
        menu->InsertItemAt(index++, OpenLinkWindow, "Open Link in New Window");
        menu->InsertItemAt(index++, OpenLinkSplit, "Open Link in Split");
      }
      menu->InsertItemAt(index++, CopyLinkAddress, "Copy Link Address");
      if (menu->GetCount() > index) menu->InsertSeparatorAt(index);
    }
    if (menu->GetCount()) menu->AddSeparator();
    menu->AddItem(InspectPage, "Inspect");
  }
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> params, int command, EventFlags flags) override {
    NSString *url = String(params->GetLinkUrl());
    if (command == CopyLinkAddress) {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
      return true;
    }
    std::optional<CVBrowserLinkDestination> destination;
    switch (command) {
      case OpenLinkTab: destination = flags & EVENTFLAG_SHIFT_DOWN ? CVBrowserLinkDestinationForegroundTab : CVBrowserLinkDestinationBackgroundTab; break;
      case OpenLinkWindow: destination = CVBrowserLinkDestinationWindow; break;
      case OpenLinkSplit: destination = CVBrowserLinkDestinationSplitRight; break;
    }
    CVChromiumView *view = view_;
    if (destination) {
      if (view.openLink && IsWebLink(url)) view.openLink(url, *destination);
      return true;
    }
    if (command != InspectPage) return false;
    CefRefPtr<ContextInspection> inspection = new ContextInspection(view_);
    inspection->Start(browser, params->GetXCoord(), params->GetYCoord());
    return true;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, const CefString& url,
                         WindowOpenDisposition disposition, bool) override {
    auto destination = LinkDestination(disposition);
    CVChromiumView *view = view_;
    return destination && view.openLink && IsWebLink(String(url)) && view.openLink(String(url), *destination);
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browsers[browser->GetIdentifier()] = browser;
    CVChromiumView *view = view_;
    if (view) view->_creating = NO;
    if (created_) { auto callback = std::move(created_); callback(); }
    if (!view || view->_closed || shutdownCompletion) { browser->GetHost()->CloseBrowser(true); return; }
    view->_browser = browser;
    browser->GetHost()->SetAccessibilityState(STATE_ENABLED);
    NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    child.frame = view->_viewportHost.bounds;
    if (view.browserReady) view.browserReady();
    [view publish];
  }
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    // Destroy only this pane's native child. The default CEF closer would
    // close Codevisor's entire workspace window.
    NSView *child = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    dispatch_async(dispatch_get_main_queue(), ^{ [child removeFromSuperview]; });
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CVChromiumView *view = view_;
    if (view) {
      if (!view->_closed && view.pageClosed) {
        void (^closed)(void) = [view.pageClosed copy];
        dispatch_async(dispatch_get_main_queue(), closed);
      }
      [view closeDevTools];
      if (view->_protocolObserver) view->_protocolObserver->Close();
      view->_protocolRegistration = nullptr; view->_protocolObserver = nullptr;
      view->_browser = nullptr;
      view->_client = nullptr;
      view->_context = nullptr;
      view->_popupWindow.delegate = nil;
      [view->_popupWindow close];
      view->_popupWindow = nil;
    }
    browsers.erase(browser->GetIdentifier());
    FinishShutdownIfReady();
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString&) override {
    if (frame->IsMain()) [view_ publish];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    title_ = String(title);
    [view_ publish];
    CVChromiumView *view = view_;
    if (view) view->_popupWindow.title = title_;
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser>, bool, bool, bool) override { [view_ publish]; }
  void OnLoadStart(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (!frame->IsMain()) return;
    CVChromiumView *view = view_;
    if (!view) return;
    ++view->_faviconGeneration;
    view->_faviconRequested = NO;
    if (view.faviconChanged) view.faviconChanged(nil);
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) override {
    if (!urls.empty()) LoadFavicon(browser, urls);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    CVChromiumView *view = view_;
    if (!frame->IsMain() || !view || view->_faviconRequested) return;
    NSURL *page = [NSURL URLWithString:String(frame->GetURL())];
    if (![@[@"http", @"https"] containsObject:page.scheme]) return;
    NSURL *fallback = [NSURL URLWithString:@"/favicon.ico" relativeToURL:page];
    LoadFavicon(browser, {String(fallback.absoluteString)});
  }
  void LoadFavicon(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls) {
    CVChromiumView *view = view_;
    if (!view || view->_closed) return;
    view->_faviconRequested = YES;
    NSUInteger generation = ++view->_faviconGeneration;
    __weak CVChromiumView *weakView = view;
    CVDownloadFavicon(browser, urls, ^(NSData *data) {
      CVChromiumView *current = weakView;
      // A response from the previous page or icon candidate must not replace
      // the current page's icon, including after a pane has closed.
      if (!current || current->_closed || current->_faviconGeneration != generation) return;
      if (current.faviconChanged) current.faviconChanged(data);
    });
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code,
                   const CefString& text, const CefString&) override {
    CVChromiumView *view = view_;
    if (frame->IsMain() && code != ERR_ABORTED && view.loadFailed) view.loadFailed(String(text));
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString&, bool isProxy,
                          const CefString& host, int port, const CefString&, const CefString&,
                          CefRefPtr<CefAuthCallback> callback) override {
    // This callback runs on CEF's IO thread. Credentials are immutable and are
    // never supplied to a website's HTTP authentication challenge.
    if (isProxy) {
      if (host.ToString() == host_ && port == port_) callback->Continue(username_, password_);
      else callback->Cancel();
      return true;
    }
    __weak CVChromiumView *weakView = view_;
    NSString *site = String(host);
    dispatch_async(dispatch_get_main_queue(), ^{
      CVChromiumView *view = weakView;
      if (!view || view->_closed || !view.window) { callback->Cancel(); return; }
      NSAlert *alert = [[NSAlert alloc] init];
      alert.messageText = [NSString stringWithFormat:@"Sign in to %@", site];
      alert.informativeText = @"This website requires a username and password.";
      [alert addButtonWithTitle:@"Sign In"]; [alert addButtonWithTitle:@"Cancel"];
      NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 64)];
      NSTextField *username = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 36, 300, 24)];
      NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
      username.placeholderString = @"Username"; password.placeholderString = @"Password";
      username.nextKeyView = password;
      [fields addSubview:username]; [fields addSubview:password]; alert.accessoryView = fields;
      [alert beginSheetModalForWindow:view.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) callback->Continue(String(username.stringValue), String(password.stringValue));
        else callback->Cancel();
      }];
    });
    return true;
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int popupID,
                     const CefString& targetURL, const CefString&, WindowOpenDisposition disposition, bool,
                     const CefPopupFeatures&, CefWindowInfo& info, CefRefPtr<CefClient>& client,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    CVChromiumView *parent = view_;
    if (!parent || parent->_closed || shutdownCompletion) return true;
    CVChromiumView *popup = [[CVChromiumView alloc] initWithProfile:parent->_profile proxyHost:parent->_proxyHost
        proxyPort:parent->_proxyPort proxyTLS:parent->_proxyTLS username:parent->_username password:parent->_password address:@"about:blank"];
    popup->_started = YES;
    popup->_context = parent->_context;
    popup->_client = new BrowserClient(popup);
    popup.openLink = parent.openLink;
    popup.adoptPopup = parent.adoptPopup;
    auto destination = LinkDestination(disposition);
    bool adopted = destination && parent.adoptPopup && parent.adoptPopup(popup, String(targetURL), *destination);
    if (!adopted) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Browser";
    window.contentView = popup;
    window.delegate = popup;
    popup->_popupWindow = window;
    [window center]; [window makeKeyAndOrderFront:nil];
    }
    pendingPopups_[popupID] = popup;
    info.SetAsChild((__bridge CefWindowHandle)popup->_viewportHost,
        CefRect(0, 0, popup->_viewportHost.bounds.size.width, popup->_viewportHost.bounds.size.height));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    client = popup->_client;
    // Creation is asynchronous. Keep both the popup and opener client alive
    // until CEF explicitly acknowledges creation or cancellation.
    popup->_client->created_ = [owner = CefRefPtr<BrowserClient>(this), popupID] {
      owner->pendingPopups_.erase(popupID);
    };
    return false;
  }
  void OnBeforePopupAborted(CefRefPtr<CefBrowser>, int popupID) override {
    auto found = pendingPopups_.find(popupID);
    if (found != pendingPopups_.end()) {
      CVChromiumView *popup = found->second;
      if (popup.pageClosed) popup.pageClosed();
      [popup closeBrowser]; pendingPopups_.erase(found);
    }
  }
  NSString *title_ = @"Browser";
  std::function<void()> created_;
 private:
  __weak CVChromiumView *view_;
  const std::string host_, username_, password_;
  const int port_;
  std::map<int, CVChromiumView *> pendingPopups_;
  IMPLEMENT_REFCOUNTING(BrowserClient);
};

@implementation CVChromiumView
- (CGFloat)setViewportWidth:(CGFloat)width height:(CGFloat)height {
  _viewportWidth = width; _viewportHeight = height;
  [self layoutViewport];
  return width > 0 && height > 0 ? MIN(1, MIN(_pageContainer.bounds.size.width / width, _pageContainer.bounds.size.height / height)) : 1;
}
- (void)layoutViewport {
  if (!_browser) return;
  NSView *child = (__bridge NSView *)_browser->GetHost()->GetWindowHandle();
  NSRect bounds = _pageContainer.bounds;
  child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  CGFloat scale = 1;
  if (_viewportWidth <= 0 || _viewportHeight <= 0) {
    _viewportHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _viewportHost.frame = bounds;
    _viewportHost.bounds = NSMakeRect(0, 0, bounds.size.width, bounds.size.height);
  } else {
    _viewportHost.autoresizingMask = NSViewNotSizable;
    scale = MIN(1, MIN(bounds.size.width / _viewportWidth, bounds.size.height / _viewportHeight));
    NSSize size = NSMakeSize(_viewportWidth * scale, _viewportHeight * scale);
    _viewportHost.frame = NSMakeRect((bounds.size.width - size.width) / 2, (bounds.size.height - size.height) / 2, size.width, size.height);
    _viewportHost.bounds = NSMakeRect(0, 0, size.width, size.height);
  }
  child.frame = _viewportHost.bounds;
  if (fabs(_viewportScale - scale) > 0.0001) {
    _viewportScale = scale;
    if (self.viewportScaleChanged) self.viewportScaleChanged(scale);
  }
  _browser->GetHost()->NotifyMoveOrResizeStarted();
}
- (BOOL)browserIsReady { return _browser && !_closed; }
- (void)sendProtocol:(NSString *)json completion:(void (^)(NSString *))completion {
  if (!_browser || _closed) { completion(@"{\"error\":{\"message\":\"Browser is not ready\"}}"); return; }
  if (!_protocolObserver) {
    _protocolObserver = new ProtocolObserver(self);
    _protocolRegistration = _browser->GetHost()->AddDevToolsMessageObserver(_protocolObserver);
  }
  NSMutableDictionary *message = [[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] mutableCopy];
  if (![message[@"method"] isKindOfClass:NSString.class]) { completion(@"{\"error\":{\"message\":\"Invalid browser command\"}}"); return; }
  static int nextRequest = 1000000000;
  int request = ++nextRequest;
  message[@"id"] = @(request);
  _protocolObserver->pending[request] = [completion copy];
  NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
  if (!_browser->GetHost()->SendDevToolsMessage(data.bytes, data.length)) {
    _protocolObserver->pending.erase(request);
    completion(@"{\"error\":{\"message\":\"Browser rejected command\"}}");
  }
}

- (instancetype)initWithProfile:(NSString *)profile proxyHost:(NSString *)host proxyPort:(NSInteger)port
                      proxyTLS:(BOOL)tls username:(NSString *)username password:(NSString *)password address:(NSString *)address {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) {
    if (!zoomViews) zoomViews = [NSHashTable weakObjectsHashTable];
    [zoomViews addObject:self];
    _profile = [profile copy]; _proxyHost = [host stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]"]]; _proxyPort = port; _proxyTLS = tls;
    _username = [username copy]; _password = [password copy]; _address = [address copy];
    self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _splitView = [[NSSplitView alloc] initWithFrame:self.bounds];
    _splitView.vertical = YES;
    _splitView.dividerStyle = NSSplitViewDividerStyleThin;
    _splitView.delegate = self;
    _splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pageContainer = [[NSView alloc] initWithFrame:self.bounds];
    [_splitView addSubview:_pageContainer];
    _viewportHost = [[NSView alloc] initWithFrame:_pageContainer.bounds];
    _viewportHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_pageContainer addSubview:_viewportHost];
    _pageFraction = 0.58;
    _pageHeightFraction = 0.60;
    NSString *dockSide = [NSUserDefaults.standardUserDefaults stringForKey:@"browserDevToolsDockSide"];
    _toolsDockSide = dockSide && IsDevToolsDockSide(dockSide) ? dockSide : @"right";
    [self addSubview:_splitView];
  }
  return self;
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (_closed || !self.window) return;
  if (_started) {
    if (_contextReady) [self createBrowser];
    return;
  }
  _started = YES;
  if (!Initialize()) { if (self.loadFailed) self.loadFailed(@"Couldn’t start Chromium."); return; }
  CefRequestContextSettings settings;
  settings.persist_session_cookies = true;
  NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString *root = [[support stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier] stringByAppendingPathComponent:@"Chromium-v2"];
  CefString(&settings.cache_path) = String([root stringByAppendingPathComponent:_profile]);
  _context = CefRequestContext::CreateContext(settings, new ContextHandler(self));
}
- (BOOL)hasOpenDevTools { return _toolsContainer != nil; }
- (BOOL)hasPageFocus {
  NSResponder *responder = self.window.firstResponder;
  return [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:_pageContainer];
}
- (void)createBrowser {
  if (_closed || _browser || _creating || !self.window || shutdownCompletion) return;
  _creating = YES;
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)_viewportHost, CefRect(0, 0, _viewportHost.bounds.size.width, _viewportHost.bounds.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  _client = new BrowserClient(self);
  if (!CefBrowserHost::CreateBrowser(info, _client, String(_address), settings, nullptr, _context)) {
    _creating = NO;
    if (self.loadFailed) self.loadFailed(@"Couldn’t create the browser page.");
  }
}
- (void)publish {
  if (!_browser || _closed) return;
  auto frame = _browser->GetMainFrame();
  if (self.stateChanged) self.stateChanged(frame ? String(frame->GetURL()) : _address,
      _client ? _client->title_ : @"Browser", _browser->IsLoading(), _browser->CanGoBack(), _browser->CanGoForward());
  [self publishZoom];
}
- (void)publishZoom {
  if (!_browser || _closed || !self.zoomChanged) return;
  auto host = _browser->GetHost();
  // Chromium's logarithmic zoom level uses a factor of 1.2 per level.
  self.zoomChanged((NSInteger)std::lround(100 * std::pow(1.2, host->GetZoomLevel())),
      host->CanZoom(CEF_ZOOM_COMMAND_OUT), host->CanZoom(CEF_ZOOM_COMMAND_IN), host->CanZoom(CEF_ZOOM_COMMAND_RESET));
}
- (void)zoom:(cef_zoom_command_t)command {
  if (!_browser || _closed) return;
  _browser->GetHost()->Zoom(command);
  // Per-site zoom is shared by pages in the same Chromium profile. Refresh
  // their controls too, including other visible splits and detached windows.
  for (CVChromiumView *view in zoomViews) [view publishZoom];
}
- (void)zoomIn { [self zoom:CEF_ZOOM_COMMAND_IN]; }
- (void)zoomOut { [self zoom:CEF_ZOOM_COMMAND_OUT]; }
- (void)resetZoom { [self zoom:CEF_ZOOM_COMMAND_RESET]; }
- (void)navigate:(NSString *)address { _address = [address copy]; if (_browser) _browser->GetMainFrame()->LoadURL(String(address)); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stop { if (_browser) _browser->StopLoad(); }
- (void)goBack { if (_browser && _browser->CanGoBack()) _browser->GoBack(); }
- (void)goForward { if (_browser && _browser->CanGoForward()) _browser->GoForward(); }
- (void)focusPage { if (_browser) _browser->GetHost()->SetFocus(true); }
- (void)showDevTools {
  if (!_browser || _closed || _toolsCreating) return;
  if (_toolsBrowser) { [self focusDevTools]; return; }
  _toolsCreating = YES;
  _toolsCloseRequested = NO;
  _toolsFrontendReady = NO;
  _toolsContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, self.bounds.size.height)];
  [self setDevToolsDockSide:_toolsDockSide];
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)_toolsContainer, CefRect(0, 0, _toolsContainer.bounds.size.width, _toolsContainer.bounds.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  auto extra = CefDictionaryValue::Create();
  extra->SetBool("codevisorDevTools", true);
  extra->SetString("dockSide", String(_toolsDockSide));
  _toolsClient = new DevToolsClient(self);
  if (!CefBrowserHost::CreateBrowser(info, _toolsClient, std::string(devToolsOrigin) + "?can_dock=true", settings, extra, _context)) {
    _toolsCreating = NO;
    _toolsClient = nullptr;
    [self removeDevTools];
  }
}
- (void)setDevToolsDockSide:(NSString *)side {
  if (!IsDevToolsDockSide(side) || !_toolsContainer || _toolsCloseRequested) return;
  BOOL undocked = [side isEqualToString:@"undocked"];
  if ([_toolsDockSide isEqualToString:side] &&
      (undocked ? _toolsWindow != nil : _toolsContainer.superview == _splitView)) return;
  // Keep the same frontend view and CDP session while changing its parent.
  // Suppress intermediate split notifications so they cannot overwrite the
  // user's preferred dimensions with a partially constructed layout.
  _layingOutTools = YES;
  _toolsDockSide = [side copy];
  // Chromium's native accessibility tree retains its old parent when the
  // host view is reparented. Rebuild that tree around the move; the browser
  // and its debugging session stay alive.
  if (_toolsBrowser) _toolsBrowser->GetHost()->SetAccessibilityState(STATE_DISABLED);
  if (_toolsWindow) {
    _toolsWindow.delegate = nil;
    _toolsWindow.contentView = nil;
    [_toolsWindow close];
    _toolsWindow = nil;
  }
  [_toolsContainer removeFromSuperview];
  _toolsContainer.autoresizingMask = NSViewNotSizable;
  if (undocked) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 650)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Developer Tools";
    window.minSize = NSMakeSize(360, 260);
    window.delegate = self;
    _toolsWindow = window;
    _toolsContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = _toolsContainer;
    [window center];
    [window makeKeyAndOrderFront:nil];
  } else {
    _splitView.vertical = ![side isEqualToString:@"bottom"];
    [_splitView addSubview:_toolsContainer positioned:[side isEqualToString:@"left"] ? NSWindowBelow : NSWindowAbove relativeTo:_pageContainer];
  }
  [self splitView:_splitView resizeSubviewsWithOldSize:_splitView.bounds.size];
  _layingOutTools = NO;
  if (_toolsBrowser) {
    _toolsBrowser->GetHost()->NotifyMoveOrResizeStarted();
    _toolsBrowser->GetHost()->SetAccessibilityState(STATE_ENABLED);
  }
  [NSUserDefaults.standardUserDefaults setObject:side forKey:@"browserDevToolsDockSide"];
  [self focusDevTools];
}
- (void)focusDevTools {
  if (_toolsCloseRequested) return;
  NSWindow *window = _toolsWindow ?: self.window;
  [window makeKeyAndOrderFront:nil];
  if (_toolsBrowser) _toolsBrowser->GetHost()->SetFocus(true);
}
- (void)inspectPendingNode {
  if (!_pendingInspection || !_toolsFrontendReady || !_toolsBrowser || _toolsCloseRequested) return;
  auto message = CefProcessMessage::Create("CodevisorDevTools.inspect");
  message->GetArgumentList()->SetInt(0, _pendingInspection);
  _pendingInspection = 0;
  _toolsBrowser->GetMainFrame()->SendProcessMessage(PID_RENDERER, message);
}
- (void)closeDevTools {
  _toolsCloseRequested = YES;
  if (_toolsBrowser) _toolsBrowser->GetHost()->CloseBrowser(true);
  else if (!_toolsCreating) [self removeDevTools];
}
- (void)removeDevTools {
  NSView *container = _toolsContainer;
  _toolsContainer = nil;
  _toolsFrontendReady = NO;
  _toolsCloseRequested = NO;
  _pendingInspection = 0;
  if (_toolsWindow) {
    _toolsWindow.delegate = nil;
    _toolsWindow.contentView = nil;
    [_toolsWindow close];
    _toolsWindow = nil;
  }
  [container removeFromSuperview];
  _pageContainer.frame = _splitView.bounds;
}
- (void)splitView:(NSSplitView *)splitView resizeSubviewsWithOldSize:(NSSize)oldSize {
  NSRect bounds = splitView.bounds;
  if (!_toolsContainer || _toolsContainer.superview != splitView) { _pageContainer.frame = bounds; [self layoutViewport]; return; }
  BOOL wasLayingOut = _layingOutTools;
  _layingOutTools = YES;
  CGFloat available = MAX(0, (splitView.isVertical ? bounds.size.width : bounds.size.height) - splitView.dividerThickness);
  CGFloat fraction = splitView.isVertical ? _pageFraction : _pageHeightFraction;
  CGFloat pageSize = round(available * MAX(0.2, MIN(0.8, fraction)));
  CGFloat toolsSize = available - pageSize;
  if (!splitView.isVertical) {
    _pageContainer.frame = NSMakeRect(0, 0, bounds.size.width, pageSize);
    _toolsContainer.frame = NSMakeRect(0, pageSize + splitView.dividerThickness, bounds.size.width, toolsSize);
  } else if ([_toolsDockSide isEqualToString:@"left"]) {
    _toolsContainer.frame = NSMakeRect(0, 0, toolsSize, bounds.size.height);
    _pageContainer.frame = NSMakeRect(toolsSize + splitView.dividerThickness, 0, pageSize, bounds.size.height);
  } else {
    _pageContainer.frame = NSMakeRect(0, 0, pageSize, bounds.size.height);
    _toolsContainer.frame = NSMakeRect(pageSize + splitView.dividerThickness, 0, toolsSize, bounds.size.height);
  }
  _layingOutTools = wasLayingOut;
  [self layoutViewport];
}
- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
  [self layoutViewport];
  if (_layingOutTools || !_toolsContainer || _toolsContainer.superview != _splitView) return;
  CGFloat available = (_splitView.isVertical ? _splitView.bounds.size.width : _splitView.bounds.size.height) - _splitView.dividerThickness;
  if (available <= 0) return;
  if (_splitView.isVertical) _pageFraction = _pageContainer.frame.size.width / available;
  else _pageHeightFraction = _pageContainer.frame.size.height / available;
}
- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {
  CGFloat extent = splitView.isVertical ? splitView.bounds.size.width : splitView.bounds.size.height;
  return MIN([_toolsDockSide isEqualToString:@"left"] ? 320 : 240, extent * 0.3);
}
- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposed ofSubviewAt:(NSInteger)index {
  CGFloat extent = splitView.isVertical ? splitView.bounds.size.width : splitView.bounds.size.height;
  CGFloat minimum = !splitView.isVertical || [_toolsDockSide isEqualToString:@"left"] ? 240 : 320;
  return extent - MIN(minimum, extent * 0.4);
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
  if (sender == _toolsWindow) [self closeDevTools];
  else [self closeBrowser];
  return NO;
}
- (void)closeBrowser {
  if (_closed) return;
  _closed = YES;
  self.stateChanged = nil; self.loadFailed = nil; self.faviconChanged = nil;
  [self closeDevTools];
  if (_browser) _browser->GetHost()->CloseBrowser(true);
  else {
    _popupWindow.delegate = nil; [_popupWindow close]; _popupWindow = nil;
    _context = nullptr; _client = nullptr;
  }
}
- (void)dealloc {
  _toolsWindow.delegate = nil;
  [_toolsWindow close];
  if (_toolsBrowser) _toolsBrowser->GetHost()->CloseBrowser(true);
  if (_browser) _browser->GetHost()->CloseBrowser(true);
}
@end
