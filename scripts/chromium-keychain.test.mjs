import { execFileSync } from "node:child_process"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { test } from "node:test"

test(
  "CEF Keychain interposition scopes app and helper queries without touching the real Keychain",
  {
    skip: process.platform !== "darwin"
  },
  () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-keychain-test-"))
    try {
      // A fake Security implementation is the actual link target of BOTH the
      // executable and the dlopened client. No path can reach the real Keychain,
      // even if interposition breaks. Test the same dyld boundary CEF crosses.
      const mock = join(directory, "MockSecurity.mm")
      writeFileSync(
        mock,
        `
#import <Foundation/Foundation.h>
#import <Security/Security.h>
static NSDictionary *captured;
extern "C" CFDictionaryRef CapturedQuery() { return (__bridge CFDictionaryRef)captured; }
OSStatus SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *) { captured = [(__bridge NSDictionary *)q copy]; return 73; }
OSStatus SecItemAdd(CFDictionaryRef q, CFTypeRef *) { captured = [(__bridge NSDictionary *)q copy]; return 73; }
OSStatus SecItemUpdate(CFDictionaryRef q, CFDictionaryRef) { captured = [(__bridge NSDictionary *)q copy]; return 73; }
OSStatus SecItemDelete(CFDictionaryRef q) { captured = [(__bridge NSDictionary *)q copy]; return 73; }
`
      )
      const client = join(directory, "Client.mm")
      writeFileSync(
        client,
        `
#import <Security/Security.h>
extern "C" OSStatus Probe(int operation, CFDictionaryRef q) {
  switch (operation) {
    case 0: return SecItemCopyMatching(q, nullptr);
    case 1: return SecItemAdd(q, nullptr);
    case 2: return SecItemUpdate(q, q);
    default: return SecItemDelete(q);
  }
}
`
      )
      const main = join(directory, "Main.mm")
      writeFileSync(
        main,
        `
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <dlfcn.h>
#include <cassert>
extern "C" CFDictionaryRef CapturedQuery();
int main(int argc, char **argv) {
  @autoreleasepool {
    assert(argc == 3);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    auto probe = (OSStatus (*)(int, CFDictionaryRef))dlsym(library, "Probe");
    assert(probe);
    NSString *expectedService = [[NSString stringWithUTF8String:argv[2]] stringByAppendingString:@".browser.safe-storage"];
    NSDictionary *query = @{
      (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService: @"Chromium Safe Storage",
      (__bridge id)kSecAttrAccount: @"Chromium",
      (__bridge id)kSecValueData: [@"fixture-encryption-key" dataUsingEncoding:NSUTF8StringEncoding],
      (__bridge id)kSecReturnAttributes: @YES
    };
    for (int operation = 0; operation < 4; ++operation) {
      assert(probe(operation, (__bridge CFDictionaryRef)query) == 73);
      NSDictionary *captured = (__bridge NSDictionary *)CapturedQuery();
      if (![captured[(__bridge id)kSecAttrService] isEqual:expectedService]) NSLog(@"Fixture bundle=%@ service=%@ expected=%@", NSBundle.mainBundle.bundleIdentifier, captured[(__bridge id)kSecAttrService], expectedService);
      assert([captured[(__bridge id)kSecAttrService] isEqual:expectedService]);
      assert([captured[(__bridge id)kSecAttrAccount] isEqual:@"Codevisor Browser"]);
      assert([captured[(__bridge id)kSecValueData] isEqual:query[(__bridge id)kSecValueData]]);
      assert([captured[(__bridge id)kSecReturnAttributes] isEqual:@YES]);
      assert([query[(__bridge id)kSecAttrService] isEqual:@"Chromium Safe Storage"]);
    }
    // Unrelated generic passwords, Chrome, certificates and partial queries
    // must pass through unchanged, including Codevisor's other credentials.
    for (NSDictionary *patch in @[
      @{(__bridge id)kSecAttrService: @"com.codevisor.cloud"},
      @{(__bridge id)kSecAttrService: @"Chrome Safe Storage", (__bridge id)kSecAttrAccount: @"Chrome"},
      @{(__bridge id)kSecAttrAccount: @"unrelated"},
      @{(__bridge id)kSecClass: (__bridge id)kSecClassCertificate}
    ]) {
      NSMutableDictionary *other = [query mutableCopy]; [other addEntriesFromDictionary:patch];
      for (int operation = 0; operation < 4; ++operation) {
        assert(probe(operation, (__bridge CFDictionaryRef)other) == 73);
        assert([(__bridge NSDictionary *)CapturedQuery() isEqual:other]);
      }
    }
    assert(probe(0, (__bridge CFDictionaryRef)@{}) == 73);
    assert([(__bridge NSDictionary *)CapturedQuery() isEqual:@{}]);
    dlclose(library);
  }
}
`
      )
      const compile = (...args) =>
        execFileSync("xcrun", ["clang++", "-std=c++20", "-fobjc-arc", ...args], { stdio: "pipe" })
      const mockLibrary = join(directory, "MockSecurity.dylib")
      compile("-dynamiclib", mock, "-framework", "Foundation", "-o", mockLibrary)
      const clientLibrary = join(directory, "Client.dylib")
      compile("-dynamiclib", client, mockLibrary, "-o", clientLibrary)
      const contents = join(directory, "Fixture.app/Contents")
      mkdirSync(join(contents, "MacOS"), { recursive: true })
      const executable = join(contents, "MacOS/Fixture")
      const adapter = fileURLToPath(
        new URL("../apps/macos/ChromiumHelper/ChromiumKeychain.mm", import.meta.url)
      )
      const storageLibrary = join(directory, "Storage.dylib")
      compile(
        "-dynamiclib",
        adapter,
        mockLibrary,
        "-framework",
        "Foundation",
        "-framework",
        "Security",
        "-o",
        storageLibrary
      )
      compile(
        main,
        `-Wl,-needed_library,${storageLibrary}`,
        mockLibrary,
        "-framework",
        "Foundation",
        "-framework",
        "Security",
        "-o",
        executable
      )
      const entitlements = join(directory, "AdHoc.entitlements")
      // Ad-hoc fixtures have no Team ID. Production signs all these dependencies
      // with the app's Team ID; this test-only exception lets ad-hoc dylibs load.
      writeFileSync(
        entitlements,
        '<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>'
      )
      for (const binary of [mockLibrary, clientLibrary, storageLibrary, executable])
        execFileSync(
          "codesign",
          [
            "--force",
            "--sign",
            "-",
            "--options",
            "runtime",
            "--timestamp=none",
            ...(binary === executable ? ["--entitlements", entitlements] : []),
            binary
          ],
          { stdio: "pipe" }
        )
      for (const owner of ["com.851labs.HerdMan", "com.codevisor.dev.fixture"]) {
        for (const suffix of [
          "",
          ".chromium.helper",
          ".chromium.helper.renderer",
          ".chromium.helper.gpu"
        ]) {
          writeFileSync(
            join(contents, "Info.plist"),
            `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${owner}${suffix}</string><key>CFBundleExecutable</key><string>Fixture</string></dict></plist>`
          )
          execFileSync(executable, [clientLibrary, owner], { stdio: "pipe" })
        }
      }
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  }
)
