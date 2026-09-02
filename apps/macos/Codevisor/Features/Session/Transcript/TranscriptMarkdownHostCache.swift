import CoreGraphics

/// Bounded identity cache for prepared native Markdown surfaces.
///
/// Rows just outside the virtual window usually return during the same scroll
/// gesture. Keeping their TextKit object graph by row identity avoids rebuilding
/// attributed storage and line fragments without retaining an entire transcript.
@MainActor
final class TranscriptMarkdownHostCache {
    private struct Entry {
        let host: TranscriptMarkdownRowHost
        let height: CGFloat
    }

    private static let maximumCount = 72
    private var entries: [String: Entry] = [:]
    private var leastRecentlyUsedKeys: [String] = []
    private var totalHeight: CGFloat = 0

    func take(for key: String) -> TranscriptMarkdownRowHost? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        leastRecentlyUsedKeys.removeAll { $0 == key }
        totalHeight -= entry.height
        return entry.host
    }

    func insert(
        _ host: TranscriptMarkdownRowHost,
        for key: String,
        height: CGFloat,
        maximumTotalHeight: CGFloat
    ) -> [TranscriptMarkdownRowHost] {
        var evicted: [TranscriptMarkdownRowHost] = []
        if let replaced = entries.removeValue(forKey: key) {
            totalHeight -= replaced.height
            leastRecentlyUsedKeys.removeAll { $0 == key }
            evicted.append(replaced.host)
        }

        let cost = max(1, height)
        entries[key] = Entry(host: host, height: cost)
        leastRecentlyUsedKeys.append(key)
        totalHeight += cost

        let heightLimit = max(1, maximumTotalHeight)
        while entries.count > Self.maximumCount || totalHeight > heightLimit {
            guard let oldestKey = leastRecentlyUsedKeys.first else { break }
            leastRecentlyUsedKeys.removeFirst()
            guard let oldest = entries.removeValue(forKey: oldestKey) else { continue }
            totalHeight -= oldest.height
            evicted.append(oldest.host)
        }
        return evicted
    }

    func removeAll() -> [TranscriptMarkdownRowHost] {
        let hosts = entries.values.map(\.host)
        entries.removeAll(keepingCapacity: false)
        leastRecentlyUsedKeys.removeAll(keepingCapacity: false)
        totalHeight = 0
        return hosts
    }
}
