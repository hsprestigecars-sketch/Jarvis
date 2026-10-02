import XCTest
@testable import JarvisCore

final class WakeWordTests: XCTestCase {
    func testNoName() {
        XCTAssertEqual(WakeWord.match("what's the weather like"), .none)
        XCTAssertEqual(WakeWord.match("call Travis tomorrow"), .none)
        XCTAssertEqual(WakeWord.match(""), .none)
    }

    func testNameOnly() {
        XCTAssertEqual(WakeWord.match("Jarvis"), .wakeOnly)
        XCTAssertEqual(WakeWord.match("Hey Jarvis."), .wakeOnly)
        XCTAssertEqual(WakeWord.match("some earlier chatter hey jarvis"), .wakeOnly)
    }

    func testNameWithCommand() {
        XCTAssertEqual(WakeWord.match("Jarvis, what's on my calendar?"), .command("what's on my calendar?"))
        XCTAssertEqual(WakeWord.match("Hey Jarvis remind me to bring my helmet"), .command("remind me to bring my helmet"))
        XCTAssertEqual(WakeWord.match("talking to my friend. Jarvis stop"), .command("stop"))
        XCTAssertEqual(WakeWord.match("J.A.R.V.I.S. take a note"), .command("take a note"))
    }

    func testUsesLastMention() {
        XCTAssertEqual(WakeWord.match("Jarvis what time is it Jarvis cancel"), .command("cancel"))
    }

    func testNameInsideWordDoesNotWake() {
        XCTAssertEqual(WakeWord.match("jarvisville is a town"), .none)
    }
}
