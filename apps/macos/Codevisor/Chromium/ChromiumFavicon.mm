#import "ChromiumFavicon.h"

namespace {
class FaviconDownload final : public CefDownloadImageCallback {
 public:
  FaviconDownload(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& urls,
                  void (^completion)(NSData *))
      : browser_(browser), urls_(urls), completion_([completion copy]) {}

  void Next() {
    if (!browser_->IsValid() || next_ >= urls_.size()) { completion_(nil); return; }
    // Chromium applies its normal favicon cookie policy and cache. The icon
    // is decoded and resized by Chromium rather than fetched via URLSession.
    browser_->GetHost()->DownloadImage(urls_[next_++], true, 32, false, this);
  }

  void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
    int width = 0, height = 0;
    auto png = image ? image->GetAsPNG(2.0, true, width, height) : nullptr;
    if (!png || !png->GetSize() || png->GetSize() > 512 * 1024) { Next(); return; }
    NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    completion_(data);
  }

 private:
  CefRefPtr<CefBrowser> browser_;
  std::vector<CefString> urls_;
  size_t next_ = 0;
  void (^completion_)(NSData *);
  IMPLEMENT_REFCOUNTING(FaviconDownload);
};
}

void CVDownloadFavicon(CefRefPtr<CefBrowser> browser,
                       const std::vector<CefString>& urls,
                       void (^completion)(NSData *)) {
  CefRefPtr<FaviconDownload> download = new FaviconDownload(browser, urls, completion);
  download->Next();
}
