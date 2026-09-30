import Testing
@testable import ChatGPTUsageCore

struct SeverityTests {
    @Test func below50IsNormal() {
        #expect(severity(forPercent: 0) == .normal)
        #expect(severity(forPercent: 49) == .normal)
    }

    @Test func fiftyTo79IsWarning() {
        #expect(severity(forPercent: 50) == .warning)
        #expect(severity(forPercent: 79) == .warning)
    }

    @Test func eightyAndAboveIsCritical() {
        #expect(severity(forPercent: 80) == .critical)
        #expect(severity(forPercent: 100) == .critical)
    }
}
