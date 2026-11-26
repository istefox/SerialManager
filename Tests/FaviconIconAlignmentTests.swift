import AppKit
import Testing

@testable import SerialManager

@MainActor
struct FaviconIconAlignmentTests {
    @Test func guideCentresTheIconOnTheCapHeight() {
        let guide = FaviconIcon.baselineGuide(size: 18, capHeight: 10)
        #expect(guide == 14)
        // Icon centre is size/2 below the top; the cap centre is capHeight/2 above the baseline.
        #expect(abs((guide - 10 / 2) - 18 / 2) < 0.001)
    }

    @Test func guideWithZeroCapHeightIsTheIconCentre() {
        #expect(FaviconIcon.baselineGuide(size: 18, capHeight: 0) == 9)
    }

    @Test func headlineCapHeightIsPositiveAndBelowTheIconSize() {
        let capHeight = FaviconIcon.headlineCapHeight
        #expect(capHeight > 0)
        #expect(capHeight < FaviconIcon.size)
    }
}
