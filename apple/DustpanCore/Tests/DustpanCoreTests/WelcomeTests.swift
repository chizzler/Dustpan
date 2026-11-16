import Testing
@testable import DustpanCore

@Suite struct WelcomeTests {
    @Test func freshProfileWaitsForAnExplicitChoice() throws {
        let store = try memoryStore()
        #expect(try prepareWelcome(store, connected: false))
        #expect(try prepareWelcome(store, connected: false))
        try completeWelcome(store)
        #expect(try !prepareWelcome(store, connected: false))
        #expect(try store.outboxCount() == 0)
    }

    @Test func existingDataSkipsWelcomeEvenAfterItIsRemoved() throws {
        let store = try memoryStore()
        try store.apply(Op(id: "seed", entity: "task", entityId: "t1", field: "title", value: "Existing", ts: 1, device: "d"))
        #expect(try !prepareWelcome(store, connected: false))
        try store.purge(entity: "task", id: "t1")
        #expect(try !prepareWelcome(store, connected: false))
    }

    @Test func configuredAccountSkipsWelcomeAfterDisconnect() throws {
        let store = try memoryStore()
        #expect(try !prepareWelcome(store, connected: true))
        #expect(try !prepareWelcome(store, connected: false))
    }
}
