import Testing
@testable import CodevisorCore

@Suite("InteractionDeferredOrder")
struct InteractionDeferredOrderTests {
    private struct Item: Equatable {
        let id: Int
        let value: String
    }

    @Test("Locked order keeps identities stable while values update")
    func retainsIdentityOrderWithCurrentValues() {
        var order = InteractionDeferredOrder<Int>()
        order.lock(to: [1, 2, 3])

        let values = [
            Item(id: 3, value: "new three"),
            Item(id: 1, value: "new one"),
            Item(id: 2, value: "new two"),
        ]

        #expect(
            order.applying(to: values, id: \.id) == [
                Item(id: 1, value: "new one"),
                Item(id: 2, value: "new two"),
                Item(id: 3, value: "new three"),
            ])
    }

    @Test("Additions stay visible and removals disappear")
    func reconcilesMembershipChanges() {
        var order = InteractionDeferredOrder<Int>()
        order.lock(to: [1, 2])

        let withAddition = [
            Item(id: 3, value: "three"),
            Item(id: 2, value: "two"),
            Item(id: 1, value: "one"),
        ]
        let firstRender = order.applying(to: withAddition, id: \.id)
        #expect(firstRender.map(\.id) == [1, 2, 3])

        order.incorporate(firstRender.map(\.id))
        let afterRemoval = [Item(id: 3, value: "three"), Item(id: 1, value: "one")]
        #expect(order.applying(to: afterRemoval, id: \.id).map(\.id) == [1, 3])
    }

    @Test("Unlock releases the latest desired order")
    func unlockReleasesOrder() {
        var order = InteractionDeferredOrder<Int>()
        order.lock(to: [1, 2])
        order.lock(to: [2, 1])

        let desired = [Item(id: 2, value: "two"), Item(id: 1, value: "one")]
        #expect(order.applying(to: desired, id: \.id).map(\.id) == [1, 2])

        order.unlock()
        #expect(order.applying(to: desired, id: \.id).map(\.id) == [2, 1])
    }
}
