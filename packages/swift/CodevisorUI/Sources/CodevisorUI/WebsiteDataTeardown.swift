import CodevisorCore
import WebKit

@MainActor
public enum WebsiteDataTeardown {
  public static func register() {
    DeviceDataTeardown.register { await run() }
  }

  static func run() async {
    await clear(.default())
    for identifier in await WKWebsiteDataStore.allDataStoreIdentifiers {
      await clear(WKWebsiteDataStore(forIdentifier: identifier))
      try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
  }

  private static func clear(_ store: WKWebsiteDataStore) async {
    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
  }
}
