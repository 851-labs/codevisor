#pragma once
#import <Foundation/Foundation.h>
#include "include/cef_browser.h"
#include <vector>

/// Downloads through the page's Chromium request context, including its proxy.
void CVDownloadFavicon(CefRefPtr<CefBrowser> browser,
                       const std::vector<CefString>& urls,
                       void (^completion)(NSData *data));
