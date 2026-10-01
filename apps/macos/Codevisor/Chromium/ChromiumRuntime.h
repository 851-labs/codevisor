#pragma once
#import "ChromiumBridge.h"
#include "include/cef_browser.h"
#include "include/wrapper/cef_library_loader.h"
#include <map>
#include <memory>

/// Owns the CEF process, its message pump, and browser shutdown accounting.
/// Browser and DevTools clients report lifecycle events without exposing the
/// registry or the timer that keeps Chromium work on the main run loop.
class ChromiumRuntime final {
 public:
  static ChromiumRuntime& Shared();
  bool Initialize();
  void SchedulePump(int64_t delay);
  void Shutdown(void (^completion)(void));
  bool HasRequestedShutdown() const { return shutdownCompletion_ != nil; }
  void BrowserDidOpen(CefRefPtr<CefBrowser> browser);
  void BrowserDidClose(CefRefPtr<CefBrowser> browser);
  void ObserveZoom(CVChromiumView *view);
  void PublishZoom();

 private:
  ChromiumRuntime() = default;
  ChromiumRuntime(const ChromiumRuntime&) = delete;
  ChromiumRuntime& operator=(const ChromiumRuntime&) = delete;
  void Pump();
  void StartPumpTimer(int64_t delay);
  bool HasBrowserWork() const;
  void FinishShutdownIfReady();

  bool initialized_ = false;
  bool shuttingDown_ = false;
  bool pumping_ = false;
  NSTimer *pumpTimer_ = nil;
  void (^shutdownCompletion_)(void) = nil;
  std::map<int, CefRefPtr<CefBrowser>> browsers_;
  NSHashTable<CVChromiumView *> *zoomViews_ = nil;
  std::unique_ptr<CefScopedLibraryLoader> library_;
};
