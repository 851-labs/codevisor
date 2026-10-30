import Foundation

enum PluginConsentRepair {
  static func repaired(_ body: Data) -> Data {
    guard var consent = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let pluginId = consent["pluginId"] as? String,
      var metadata = consent["metadata"] as? [String: Any]
    else { return body }
    guard isMissing(metadata["publisher"]) || isMissing(metadata["version"]) else { return body }

    fill(&metadata, "publisher", with: PluginModerationSubject.publisher(ofPluginId: pluginId))
    if PluginModerationSubject.isCustom(pluginId: pluginId) {
      fill(&metadata, "version", with: PluginConsentMetadata.customVersion)
    }
    consent["metadata"] = metadata
    return (try? JSONSerialization.data(withJSONObject: consent)) ?? body
  }

  private static func fill(_ metadata: inout [String: Any], _ field: String, with value: String) {
    guard isMissing(metadata[field]), !value.isEmpty else { return }

    metadata[field] = value
  }

  private static func isMissing(_ value: Any?) -> Bool {
    (value as? String)?.isEmpty ?? true
  }
}
