import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct HomeDayGroupTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func take(_ id: String, _ date: Date) -> HomeTake {
        HomeTake(id: id, startedAt: date, text: id, appName: nil, recoverable: nil)
    }

    @Test func groupsByDayKeepingNewestFirstOrder() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))!
        let takes = [
            take("a", now.addingTimeInterval(-60)),
            take("b", now.addingTimeInterval(-3600)),
            take("c", now.addingTimeInterval(-86_400)),
            take("d", now.addingTimeInterval(-86_400 * 5)),
        ]
        let groups = HomeDayGroup.group(takes, now: now, calendar: calendar)
        #expect(groups.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(groups.map { $0.takes.map(\.id) } == [["a", "b"], ["c"], ["d"]])
        #expect(groups[2].title != "Today" && groups[2].title != "Yesterday")
    }

    @Test func emptyInputMakesNoGroups() {
        #expect(HomeDayGroup.group([], now: Date(), calendar: calendar).isEmpty)
    }
}
