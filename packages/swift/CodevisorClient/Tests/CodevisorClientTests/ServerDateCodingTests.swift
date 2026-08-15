import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

struct ServerDateCodingTests {
    @Test func parsesFractionalAndWholeSecondServerDates() throws {
        let fractional = try ServerDateCoding.date(from: "2026-08-13T21:01:02.345Z")
        let whole = try ServerDateCoding.date(from: "2026-08-13T21:01:02Z")

        #expect(abs(fractional.timeIntervalSince(whole) - 0.345) < 0.000_1)
        #expect(ServerDateCoding.string(from: fractional).hasSuffix(".345Z"))
    }

    @Test func cachedFormattersAreSafeAcrossConcurrentSnapshotBuilders() async {
        let values = await withTaskGroup(of: Date?.self, returning: [Date?].self) { group in
            for index in 0..<200 {
                group.addTask {
                    try? ServerDateCoding.date(
                        from: "2026-08-13T21:01:02.\(String(format: "%03d", index % 1000))Z"
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(values.count == 200)
        #expect(values.allSatisfy { $0 != nil })
    }
}
