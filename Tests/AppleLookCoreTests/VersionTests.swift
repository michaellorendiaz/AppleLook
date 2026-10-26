import Testing
@testable import AppleLookCore

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(Version.isNewer("v0.2.0", than: "0.1.0"))
        #expect(Version.isNewer("0.10.0", than: "0.9.3"))
        #expect(Version.isNewer("1.0", than: "0.9.9"))
        #expect(!Version.isNewer("v0.1.0", than: "0.1.0"))
        #expect(!Version.isNewer("0.1", than: "0.1.0"))
        #expect(!Version.isNewer("0.1.0", than: "0.2.0"))
    }
}
