import Testing
@testable import AuralCore

struct AuralVersionTests {
    @Test func versionComparisonUsesNumericComponents() throws {
        let older = try #require(AuralVersionNumber("v0.1.9"))
        let newer = try #require(AuralVersionNumber("0.1.10"))
        let stable = try #require(AuralVersionNumber("0.2.0"))
        let prerelease = try #require(AuralVersionNumber("0.2.0-beta.1"))
        let betaTwo = try #require(AuralVersionNumber("0.2.0-beta.2"))
        let betaTen = try #require(AuralVersionNumber("0.2.0-beta.10"))

        #expect(older < newer)
        #expect(prerelease < stable)
        #expect(betaTwo < betaTen)
    }

    @Test(arguments: ["", "v", "1.x.0", "1..2"])
    func invalidVersionStringsAreRejected(value: String) {
        #expect(AuralVersionNumber(value) == nil)
    }
}
