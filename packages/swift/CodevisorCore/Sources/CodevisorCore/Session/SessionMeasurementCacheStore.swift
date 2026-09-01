/// Revision-keyed settled-row measurements retained across transcript mounts.
///
/// The store owns LRU bookkeeping and keeps the currently publishable settled
/// snapshot aligned with the active width/layout key. Dictionary snapshots are
/// copy-on-write, so publishing scroll state stays cheap.
public struct SessionMeasurementCacheStore {
    private let maximumCacheCount: Int
    private var storage: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]] = [:]
    private var recency: [SessionMeasurementCacheKey] = []

    public private(set) var activeKey: SessionMeasurementCacheKey?
    public private(set) var settledRows: [String: SessionMeasuredRow] = [:]

    public var caches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]] {
        storage
    }

    public var lru: [SessionMeasurementCacheKey] {
        recency
    }

    public init(maximumCacheCount: Int = 3) {
        precondition(maximumCacheCount > 0)
        self.maximumCacheCount = maximumCacheCount
    }

    public mutating func restore(
        caches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]],
        lru: [SessionMeasurementCacheKey]
    ) {
        storage = caches
        recency = lru.filter { caches[$0] != nil }
        activeKey = nil
        settledRows = [:]
    }

    /// Makes a width/layout key current and returns its retained measurements.
    @discardableResult
    public mutating func activate(
        _ key: SessionMeasurementCacheKey
    ) -> [String: SessionMeasuredRow] {
        activeKey = key
        recency.removeAll { $0 == key }
        recency.append(key)
        while recency.count > maximumCacheCount {
            storage.removeValue(forKey: recency.removeFirst())
        }
        return storage[key] ?? [:]
    }

    public mutating func replaceActiveMeasurements(
        _ measurements: [String: SessionMeasuredRow]
    ) {
        settledRows = measurements
        if let activeKey {
            storage[activeKey] = measurements
        }
    }

    public mutating func removeMeasurement(for rowKey: String) {
        settledRows.removeValue(forKey: rowKey)
        if let activeKey {
            storage[activeKey]?.removeValue(forKey: rowKey)
        }
    }

    public mutating func store(
        _ measurement: SessionMeasuredRow,
        for rowKey: String
    ) {
        settledRows[rowKey] = measurement
        if let activeKey {
            storage[activeKey, default: [:]][rowKey] = measurement
        }
    }
}
