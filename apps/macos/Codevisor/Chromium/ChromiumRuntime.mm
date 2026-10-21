#import "ChromiumRuntime.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include <vector>

@interface CVChromiumView (Runtime)
- (void)publishZoom;
@property(nonatomic, readonly) BOOL keepsRuntimeAwake;
@end

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
CefString RuntimeString(NSString *value) { return CefString(value.UTF8String ?: ""); }
class Application final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    command->AppendSwitch("disable-chrome-login-prompt");
    command->AppendSwitch("disable-quic");
    command->AppendSwitch("disable-background-timer-throttling");
    command->AppendSwitch("disable-renderer-backgrounding");
    command->AppendSwitch("disable-backgrounding-occluded-windows");
  }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    dispatch_async(dispatch_get_main_queue(), ^{ ChromiumRuntime::Shared().SchedulePump(delay); });
  }
 private:
  IMPLEMENT_REFCOUNTING(Application);
};
}

ChromiumRuntime& ChromiumRuntime::Shared() {
  static ChromiumRuntime runtime;
  return runtime;
}

void ChromiumRuntime::Pump() {
  if (!initialized_ || shuttingDown_ || pumping_) return;
  pumping_ = true;
  CefDoMessageLoopWork();
  pumping_ = false;
  if (!pumpTimer_) StartPumpTimer(HasBrowserWork() ? 33 : 1000);
}
bool ChromiumRuntime::HasBrowserWork() const {
  if (!browsers_.empty()) return true;
  for (CVChromiumView *view in zoomViews_) {
    if (view.keepsRuntimeAwake) return true;
  }
  return false;
}
void ChromiumRuntime::SchedulePump(int64_t delay) { StartPumpTimer(MAX(0, MIN(delay, 33))); }
void ChromiumRuntime::StartPumpTimer(int64_t delay) {
  [pumpTimer_ invalidate];
  pumpTimer_ = nil;
  if (!initialized_ || shuttingDown_) return;
  pumpTimer_ = [NSTimer timerWithTimeInterval:delay / 1000.0
                                   repeats:NO block:^(NSTimer *timer) {
    pumpTimer_ = nil;
    Pump();
  }];
  [NSRunLoop.mainRunLoop addTimer:pumpTimer_ forMode:NSRunLoopCommonModes];
}
bool ChromiumRuntime::Initialize() {
  if (initialized_) {
    if (!shuttingDown_) SchedulePump(0);
    return !shuttingDown_;
  }
  if (shuttingDown_) return false;
  library_ = std::make_unique<CefScopedLibraryLoader>();
  if (!library_->LoadInMain()) return false;
  CefSettings settings;
  settings.external_message_pump = true;
  settings.log_severity = LOGSEVERITY_WARNING;
  NSString *support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString *root = [[support stringByAppendingPathComponent:NSBundle.mainBundle.bundleIdentifier] stringByAppendingPathComponent:@"Chromium-v2"];
  CefString(&settings.root_cache_path) = RuntimeString(root);
  CefString(&settings.log_file) = RuntimeString([root stringByAppendingPathComponent:@"chromium.log"]);
  NSString *appName = NSBundle.mainBundle.executablePath.lastPathComponent;
  NSString *helperName = [appName stringByReplacingOccurrencesOfString:@"Codevisor" withString:@"Codevisor Browser Helper"
                                                              options:NSAnchoredSearch range:NSMakeRange(0, appName.length)];
  NSString *helperBundle = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:[helperName stringByAppendingString:@".app"]];
  NSString *helper = [NSBundle bundleWithPath:helperBundle].executablePath;
  if (!helper) return false;
  CefString(&settings.browser_subprocess_path) = RuntimeString(helper);
  std::vector<std::string> arguments;
  for (NSString *argument in NSProcessInfo.processInfo.arguments) arguments.emplace_back(argument.UTF8String);
  std::vector<char *> argv;
  for (auto& argument : arguments) argv.push_back(argument.data());
  CefMainArgs args((int)argv.size(), argv.data());
  initialized_ = CefInitialize(args, settings, new Application(), nullptr);
  if (initialized_) SchedulePump(0);
  return initialized_;
}
void ChromiumRuntime::FinishShutdownIfReady() {
  if (!shutdownCompletion_ || !browsers_.empty()) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!shutdownCompletion_ || !browsers_.empty()) return;
    shuttingDown_ = true;
    [pumpTimer_ invalidate]; pumpTimer_ = nil;
    if (initialized_) CefShutdown();
    initialized_ = false;
    auto completion = shutdownCompletion_;
    shutdownCompletion_ = nil;
    completion();
  });
}

void ChromiumRuntime::Shutdown(void (^completion)(void)) {
  if (!initialized_) { completion(); return; }
  shutdownCompletion_ = [completion copy];
  auto open = browsers_;
  for (const auto& entry : open) entry.second->GetHost()->CloseBrowser(true);
  FinishShutdownIfReady();
}

void ChromiumRuntime::BrowserDidOpen(CefRefPtr<CefBrowser> browser) {
  browsers_[browser->GetIdentifier()] = browser;
}
void ChromiumRuntime::BrowserDidClose(CefRefPtr<CefBrowser> browser) {
  browsers_.erase(browser->GetIdentifier());
  FinishShutdownIfReady();
}
void ChromiumRuntime::ObserveZoom(CVChromiumView *view) {
  if (!zoomViews_) zoomViews_ = [NSHashTable weakObjectsHashTable];
  [zoomViews_ addObject:view];
}
void ChromiumRuntime::PublishZoom() {
  for (CVChromiumView *view in zoomViews_) [view publishZoom];
}
void CVShutdownChromium(void (^completion)(void)) {
  ChromiumRuntime::Shared().Shutdown(completion);
}
BOOL CVChromiumIsPumping(void) {
  return ChromiumRuntime::Shared().IsPumping();
}
