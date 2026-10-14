#pragma once
#import <Foundation/Foundation.h>
#include "include/cef_browser.h"
#include <vector>

void CVDownloadFavicon(CefRefPtr<CefBrowser> browser,
                       const std::vector<CefString>& urls,
                       void (^completion)(NSData *data));
