#import <Foundation/Foundation.h>
#import <Security/Security.h>

// CEF 152 does not expose Chromium's runtime Keychain name configuration.
// Keep this adapter pinned to its exact generic-password query, in both the
// app and its helpers. Remove it when CEF exposes keychain_service_name:
// https://github.com/chromiumembedded/cef/pull/4247
// Only the item identity changes. Security.framework still controls access,
// and Chromium still generates a random key and encrypts its profile data.
static NSDictionary *BrowserKeychainQuery(NSDictionary *query, NSString *bundleIdentifier) {
  if (![query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
      || ![query[(__bridge id)kSecAttrService] isEqual:@"Chromium Safe Storage"]
      || ![query[(__bridge id)kSecAttrAccount] isEqual:@"Chromium"]) return query;
  // Helper bundle IDs are generated from the owning app's bundle ID. This
  // also isolates each development worktree from the production app.
  NSString *owner = [bundleIdentifier componentsSeparatedByString:@".chromium.helper"].firstObject;
  if (owner.length == 0) return nil; // Never fall through to Chromium's shared item.
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

// Static dyld interposition works when CEF is loaded with dlopen; it needs no
// injected library, environment override, or writes to executable memory.
__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement; const void *original; } browserKeychainInterposers[] = {
  { (const void *)BrowserItemCopyMatching, (const void *)SecItemCopyMatching },
  { (const void *)BrowserItemAdd, (const void *)SecItemAdd },
  { (const void *)BrowserItemUpdate, (const void *)SecItemUpdate },
  { (const void *)BrowserItemDelete, (const void *)SecItemDelete },
};
