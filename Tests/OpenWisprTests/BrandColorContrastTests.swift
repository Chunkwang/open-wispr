import AppKit
import SwiftUI
import XCTest
@testable import OpenWisprLib

/// WCAG 2.x contrast for `BrandColor`'s own semantic colours — `success`,
/// `danger`, `warning` and their `Light`/`Dark` variants — against
/// `BrandColor`'s own backgrounds (Task 6.2). This is a separate file from
/// `ContrastTests`, which audits a different, already-shipped set of hex
/// values: the sign-in window's `SignInPalette` tokens. A couple of
/// `SignInPalette`'s own tokens (`successGlyph`, `dangerOnDark`,
/// `dangerOnLight`) happen to share a name or a hex value with something
/// here, but they are defined independently in `SignInPalette.swift` and are
/// already covered by `ContrastTests` — nothing in this file changes that.
///
/// As of this writing, grepping `Sources/` for `BrandColor.success`,
/// `BrandColor.danger`, `BrandColor.warning` (bare and `Light`/`Dark`) and
/// the `success(for:)`/`danger(for:)`/`warning(for:)`/`background(for:)`/
/// `text(for:)` helpers finds no call site anywhere outside `BrandColor.swift`
/// itself — the whole semantic system is dormant, exactly as
/// `brand-color-system.md` section 3 says ("in v1, this semantic system is
/// mostly dormant") and its per-colour table says explicitly ("Use in v1:
/// Not used yet" for both danger and warning). Per Task 6.2's own scope note
/// ("Amber and danger are dormant in v1, so only fix what ships"), every
/// pairing below is still asserted — so an accidental hex edit still fails
/// loudly — but a pairing that fails only gets its real, failing number
/// asserted (never forced to pass) when nothing ships with it yet. Fix the
/// token, not this test, the day a real call site appears.
final class BrandColorContrastTests: XCTestCase {
    private func rgb(_ color: Color) -> (r: Int, g: Int, b: Int) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
    }

    private func hex(_ color: Color) -> UInt32 {
        let c = rgb(color)
        return UInt32(c.r << 16 | c.g << 8 | c.b)
    }

    private func ratio(_ fg: Color, _ bg: Color) -> Double {
        ContrastTests.contrastRatio(rgb(fg), rgb(bg))
    }

    // MARK: - success / danger: every pairing already passes, shipped or not

    /// The scheme-correct wiring (`success(for:)`'s own choice of variant per
    /// background) as body text: both pass the 4.5:1 text threshold.
    func testSuccessTextPairsPassAtFourPointFive() {
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.successLight, BrandColor.lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.successDark, BrandColor.darkBackground), 4.5)
    }

    func testDangerTextPairsPassAtFourPointFive() {
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.dangerLight, BrandColor.lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.dangerDark, BrandColor.darkBackground), 4.5)
    }

    /// The base (scheme-agnostic) `success`/`danger` tokens, as a large-text
    /// or UI-component colour (icon, border, fill) on either background.
    func testSuccessAndDangerBaseColoursPassAsUIElementsOnBothBackgrounds() {
        for bg in [BrandColor.darkBackground, BrandColor.lightBackground] {
            XCTAssertGreaterThanOrEqual(ratio(BrandColor.success, bg), 3.0)
            XCTAssertGreaterThanOrEqual(ratio(BrandColor.danger, bg), 3.0)
        }
    }

    /// White label on a filled button, the same category
    /// `BrandColor.swift`'s own doc comment uses for emerald ("white on
    /// emerald is 4.50:1 ... passes AA for large text and UI").
    func testWhiteLabelOnSuccessAndDangerFillsPassAsUIElements() {
        let white = Color.white
        for color in [BrandColor.success, BrandColor.successLight, BrandColor.successDark,
                      BrandColor.danger, BrandColor.dangerLight, BrandColor.dangerDark] {
            XCTAssertGreaterThanOrEqual(ratio(white, color), 3.0)
        }
    }

    // MARK: - warning: dormant, and the only family with a real failure

    /// `warningLight` on `lightBackground` is ~4.15:1 — fails the 4.5:1 text
    /// threshold. `warning` has no call site anywhere in the app today (see
    /// class doc comment) and `brand-color-system.md`'s own table says
    /// "Use in v1: Not used yet" — so this documents the real number instead
    /// of lightening the token for a colour nothing renders yet. If
    /// `warningLight` ever becomes real body text, lighten the token, not
    /// this assertion.
    func testWarningLightOnLightTextPairIsDormantAndFails() {
        let value = ratio(BrandColor.warningLight, BrandColor.lightBackground)
        XCTAssertEqual(value, 4.15, accuracy: 0.01)
        XCTAssertLessThan(value, 4.5, "warningLight on lightBackground: \(value) — fails 4.5:1; dormant in v1, see class doc comment")
    }

    /// The dark-mode variant does pass, for whenever/if `warning` ships
    /// dark-mode-first.
    func testWarningDarkOnDarkTextPairPasses() {
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.warningDark, BrandColor.darkBackground), 4.5)
    }

    func testWarningBaseColourAsUIElementOnBothBackgroundsPasses() {
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.warning, BrandColor.darkBackground), 3.0)
        XCTAssertGreaterThanOrEqual(ratio(BrandColor.warning, BrandColor.lightBackground), 3.0)
    }

    /// White label on an amber (`warning`) fill is the exact pairing
    /// `murmur-implementation-plan.md` finding 12 calls out as a known
    /// failure ("white on amber is 3.25:1, fails"). It clears the 3:1
    /// large-text/UI floor but not the stricter 4.5:1 this project otherwise
    /// holds body text to, so it is still documented as failing, matching
    /// the plan's own call. `warning` has no shipping button anywhere in the
    /// app today — dormant, not fixed here.
    func testWhiteOnWarningFillIsDormantAndFails() {
        let onWarning = ratio(Color.white, BrandColor.warning)
        XCTAssertEqual(onWarning, 3.25, accuracy: 0.01)
        XCTAssertLessThan(onWarning, 4.5)

        let onWarningDark = ratio(Color.white, BrandColor.warningDark)
        XCTAssertLessThan(onWarningDark, 3.0, "white on warningDark: \(onWarningDark) — fails even the 3:1 UI floor; dormant in v1")
    }

    func testWhiteOnWarningLightPasses() {
        XCTAssertGreaterThanOrEqual(ratio(Color.white, BrandColor.warningLight), 3.0)
    }

    // MARK: - Helper-function wiring: the scheme-dispatch helpers must return
    // exactly the variant this file audited, or the audit above is auditing
    // the wrong colour.

    func testSchemeHelpersReturnTheAuditedVariant() {
        XCTAssertEqual(hex(BrandColor.success(for: .light)), hex(BrandColor.successLight))
        XCTAssertEqual(hex(BrandColor.success(for: .dark)), hex(BrandColor.successDark))
        XCTAssertEqual(hex(BrandColor.danger(for: .light)), hex(BrandColor.dangerLight))
        XCTAssertEqual(hex(BrandColor.danger(for: .dark)), hex(BrandColor.dangerDark))
        XCTAssertEqual(hex(BrandColor.warning(for: .light)), hex(BrandColor.warningLight))
        XCTAssertEqual(hex(BrandColor.warning(for: .dark)), hex(BrandColor.warningDark))
        XCTAssertEqual(hex(BrandColor.background(for: .light)), hex(BrandColor.lightBackground))
        XCTAssertEqual(hex(BrandColor.background(for: .dark)), hex(BrandColor.darkBackground))
    }
}
