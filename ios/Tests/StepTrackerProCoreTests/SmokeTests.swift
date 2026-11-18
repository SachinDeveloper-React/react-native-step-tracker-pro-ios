import XCTest
@testable import StepTrackerProCore

final class SmokeTests: XCTestCase {
    func testJSONWritesIntegersAsIntegers() {
        XCTAssertEqual(JSON.object([("a", .double(1.0)), ("b", .double(0.5)), ("c", .double(.nan))]).serialized(),
                       #"{"a":1,"b":0.5,"c":null}"#)
    }
}
