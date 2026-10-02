import XCTest
@testable import JarvisCore

final class CommandTests: XCTestCase {
    func testStopAndCancel() {
        XCTAssertEqual(CommandProcessor.classify("JARVIS, STOP.", hasPendingConfirmation: false), .emergencyStop)
        XCTAssertEqual(CommandProcessor.classify("hey jarvis stop everything", hasPendingConfirmation: false), .emergencyStop)
        XCTAssertEqual(CommandProcessor.classify("Cancel.", hasPendingConfirmation: true), .cancel)
        XCTAssertEqual(CommandProcessor.classify("no", hasPendingConfirmation: true), .cancel)
        XCTAssertEqual(CommandProcessor.classify("no", hasPendingConfirmation: false), .forward("no"))
        XCTAssertEqual(CommandProcessor.classify("Confirm", hasPendingConfirmation: true), .confirm)
        XCTAssertEqual(CommandProcessor.classify("Confirm", hasPendingConfirmation: false), .forward("Confirm"))
    }

    func testWakeWordStripping() {
        XCTAssertEqual(CommandProcessor.stripWakeWord("Hey JARVIS, what's on my calendar?"), "what's on my calendar?")
        XCTAssertEqual(CommandProcessor.stripWakeWord("Jarvisville is a town"), "Jarvisville is a town")
        XCTAssertEqual(CommandProcessor.classify("JARVIS", hasPendingConfirmation: false), .empty)
    }

    func testProtectedRequest() {
        if case .protected = CommandProcessor.classify("JARVIS, send $200 to Sam", hasPendingConfirmation: false) {} else {
            XCTFail("financial transfer must be protected")
        }
    }
}
