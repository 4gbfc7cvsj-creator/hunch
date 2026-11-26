import Testing
@testable import HunchPolicy

@Suite struct EndpointHealthTests {
    @Test func skippedForThirtySecondsAfterAFailure() {
        var health = EndpointHealth()
        let t0 = ContinuousClock.now
        #expect(health.isAvailable(now: t0))
        health.markFailed(now: t0)
        #expect(!health.isAvailable(now: t0 + .seconds(29)))
        #expect(health.isAvailable(now: t0 + .seconds(30)))
    }

    @Test func aSuccessClearsTheFailure() {
        var health = EndpointHealth()
        health.markFailed()
        health.markSucceeded()
        #expect(health.isAvailable())
        #expect(health.failedAt == nil)
    }
}
