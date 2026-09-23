import XCTest
@testable import TaskTickApp

/// The task ID a banner carries has to survive the trip through
/// `UNNotificationContent.userInfo` for a tap to land on that task.
final class NotificationTapTargetTests: XCTestCase {

    func testTaskIdRoundTrips() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = NotificationManager.userInfo(taskId: id)
        XCTAssertEqual(NotificationManager.taskId(from: userInfo), id)
    }

    func testBannersWithoutTaskCarryNoTaskId() {
        XCTAssertNil(NotificationManager.taskId(from: [:]))
        XCTAssertNil(NotificationManager.taskId(from: [NotificationManager.openMainWindowKey: true]))
    }

    func testMalformedTaskIdIsIgnored() {
        XCTAssertNil(NotificationManager.taskId(from: [NotificationManager.taskIdKey: "not-a-uuid"]))
        XCTAssertNil(NotificationManager.taskId(from: [NotificationManager.taskIdKey: 42]))
    }
}
