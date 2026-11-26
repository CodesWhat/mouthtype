import Testing

@testable import MouthtypeCore

struct TimingBudgetTests {
    @Test func localRunsKeepTheTightBudget() {
        #expect(TextTestSupport.scale(environment: [:]) == 1)
    }

    @Test func ciRunsGetAGenerousButFiniteCeiling() {
        let scale = TextTestSupport.scale(environment: ["CI": "true"])
        #expect(scale == TextTestSupport.ciTimingScale)
        #expect(scale > 1 && scale.isFinite)
    }
}
