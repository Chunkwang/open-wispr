import XCTest
@testable import OpenWisprLib

final class BoundingBoxOverlayTests: XCTestCase {
    func testParseNoBoxes() {
        let text = "This is a normal answer with no box tags."
        let result = BoundingBoxParser.parse(text)
        XCTAssertEqual(result.cleanText, text)
        XCTAssertTrue(result.boxes.isEmpty)
    }

    func testParseSingleBoxWithoutLabel() {
        let input = "The button is here. <box>100,200,300,400</box>"
        let result = BoundingBoxParser.parse(input)
        XCTAssertEqual(result.cleanText, "The button is here.")
        XCTAssertEqual(result.boxes.count, 1)
        XCTAssertEqual(result.boxes[0].ymin, 100)
        XCTAssertEqual(result.boxes[0].xmin, 200)
        XCTAssertEqual(result.boxes[0].ymax, 300)
        XCTAssertEqual(result.boxes[0].xmax, 400)
        XCTAssertNil(result.boxes[0].label)
    }

    func testParseSingleBoxWithLabel() {
        let input = "Click on the save button <box label=\"Save Button\">80.5,720,130,850.5</box> in the toolbar."
        let result = BoundingBoxParser.parse(input)
        XCTAssertEqual(result.cleanText, "Click on the save button  in the toolbar.")
        XCTAssertEqual(result.boxes.count, 1)
        XCTAssertEqual(result.boxes[0].label, "Save Button")
        XCTAssertEqual(result.boxes[0].ymin, 80.5)
        XCTAssertEqual(result.boxes[0].xmin, 720)
        XCTAssertEqual(result.boxes[0].ymax, 130)
        XCTAssertEqual(result.boxes[0].xmax, 850.5)
    }

    func testRectConversionInScreenFrame() {
        let box = NormalizedBox(ymin: 100, xmin: 200, ymax: 300, xmax: 400, label: "Test")
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let rect = box.rect(in: screenFrame)

        XCTAssertEqual(rect.origin.x, 200)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 200)
        // macOS screen origin is bottom-left. ymax=300 -> 1.0 - 0.3 = 0.7 * 1000 = 700
        XCTAssertEqual(rect.origin.y, 700)
    }

    /// Ask's screenshot is now scoped to the frontmost window rather than the
    /// whole display (the privacy fix this test guards), so the model's 0-1000
    /// normalized box is relative to that window — a window that is virtually
    /// never at the display's origin. A frame starting at (0,0), as every
    /// other test here uses, cannot tell a correct offset-aware conversion
    /// apart from one that silently ignores `screenFrame.origin` entirely, so
    /// this exercises a window at (400, 200) partway across a 1600x1000
    /// display.
    func testRectConversionForWindowNotAtDisplayOrigin() {
        let box = NormalizedBox(ymin: 100, xmin: 200, ymax: 300, xmax: 400, label: "Test")
        // A 1000x1000 window whose bottom-left corner sits at (400, 200) in
        // AppKit/NSScreen coordinates (origin bottom-left of the display).
        let windowFrame = CGRect(x: 400, y: 200, width: 1000, height: 1000)
        let rect = box.rect(in: windowFrame)

        // x is the window's own xmin (200/1000 of its width) plus the
        // window's offset from the display's origin.
        XCTAssertEqual(rect.origin.x, 400 + 200)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 200)
        // Y still flips within the window's own height, then the window's
        // vertical offset is added back in: 200 + (1.0 - 0.3) * 1000 = 900.
        XCTAssertEqual(rect.origin.y, 200 + 700)
    }

    /// Same window-not-at-origin case, but on a window small enough and
    /// placed far enough from the origin that forgetting the offset (using
    /// only `screenFrame.width`/`height` the way a naive "just use the box
    /// percentages against the window's own size" conversion would) produces
    /// a box nowhere near the one the offset-aware conversion produces —
    /// making a regression here obvious rather than a few points off.
    func testRectConversionForSmallWindowFarFromOrigin() {
        let box = NormalizedBox(ymin: 0, xmin: 0, ymax: 500, xmax: 500, label: nil)
        let windowFrame = CGRect(x: 1200, y: 700, width: 400, height: 300)
        let rect = box.rect(in: windowFrame)

        XCTAssertEqual(rect.origin.x, 1200)
        XCTAssertEqual(rect.width, 200)
        XCTAssertEqual(rect.height, 150)
        // ymax=500 -> (1.0 - 0.5) * 300 = 150, plus the window's minY of 700.
        XCTAssertEqual(rect.origin.y, 850)

        // Without the window's origin folded in, the box would land inside
        // the first 200x150 points of the *display* instead.
        XCTAssertNotEqual(rect.origin.x, 0)
        XCTAssertNotEqual(rect.origin.y, 150)
    }
}
