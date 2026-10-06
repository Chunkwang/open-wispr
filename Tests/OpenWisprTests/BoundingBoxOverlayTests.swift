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
}
