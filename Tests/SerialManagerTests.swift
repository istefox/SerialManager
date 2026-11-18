import Testing
@testable import SerialManager

struct AppInfoTests {
    @Test func displayNameMatchesProduct() {
        #expect(AppInfo.displayName == "SerialManager")
    }

    @Test func taglineIsNotEmpty() {
        #expect(!AppInfo.tagline.isEmpty)
    }
}
