#import <Foundation/Foundation.h>
#import <Security/Security.h>

static NSDictionary *BrowserKeychainQuery(NSDictionary *query, NSString *bundleIdentifier) {
  if (![query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
      || ![query[(__bridge id)kSecAttrService] isEqual:@"Chromium Safe Storage"]
      || ![query[(__bridge id)kSecAttrAccount] isEqual:@"Chromium"]) return query;
  NSString *owner = [bundleIdentifier componentsSeparatedByString:@".chromium.helper"].firstObject;
  if (owner.length == 0) return nil;
  NSMutableDictionary *scoped = [query mutableCopy];
  scoped[(__bridge id)kSecAttrService] = [owner stringByAppendingString:@".browser.safe-storage"];
  scoped[(__bridge id)kSecAttrAccount] = @"Codevisor Browser";
  return scoped;
}


static OSStatus BrowserItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  @autoreleasepool {
    NSDictionary *scoped = BrowserKeychainQuery((__bridge NSDictionary *)query, NSBundle.mainBundle.bundleIdentifier);
    return scoped ? SecItemCopyMatching((__bridge CFDictionaryRef)scoped, result) : errSecParam;
  }
}
static OSStatus BrowserItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
  @autoreleasepool {
    NSDictionary *scoped = BrowserKeychainQuery((__bridge NSDictionary *)attributes, NSBundle.mainBundle.bundleIdentifier);
    return scoped ? SecItemAdd((__bridge CFDictionaryRef)scoped, result) : errSecParam;
  }
}
static OSStatus BrowserItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
  @autoreleasepool {
    NSDictionary *scoped = BrowserKeychainQuery((__bridge NSDictionary *)query, NSBundle.mainBundle.bundleIdentifier);
    return scoped ? SecItemUpdate((__bridge CFDictionaryRef)scoped, attributes) : errSecParam;
  }
}
static OSStatus BrowserItemDelete(CFDictionaryRef query) {
  @autoreleasepool {
    NSDictionary *scoped = BrowserKeychainQuery((__bridge NSDictionary *)query, NSBundle.mainBundle.bundleIdentifier);
    return scoped ? SecItemDelete((__bridge CFDictionaryRef)scoped) : errSecParam;
  }
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } browserKeychainInterposers[] = {
  { (const void *)BrowserItemCopyMatching, (const void *)SecItemCopyMatching },
  { (const void *)BrowserItemAdd, (const void *)SecItemAdd },
  { (const void *)BrowserItemUpdate, (const void *)SecItemUpdate },
  { (const void *)BrowserItemDelete, (const void *)SecItemDelete },
};
