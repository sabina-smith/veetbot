import EventKit
import Foundation

/// The owner's Calendar app, read-only. It already syncs their Google and
/// iCloud calendars, so once the owner connects it every helper sees their
/// trips, dinners and travel days instead of asking for them.
@MainActor
final class CalendarSource {
    static let shared = CalendarSource()
    private let store = EKEventStore()

    enum Status: String { case connected, notConnected = "not_connected", denied }

    var status: Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .connected
        case .denied, .restricted, .writeOnly: return .denied
        default: return .notConnected
        }
    }

    /// Asks macOS for access; the system shows its own prompt the first time.
    func connect() async -> Status {
        guard status == .notConnected else { return status }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        return granted ? .connected : .denied
    }

    /// One line per event from `pastDays` ago to `days` ahead, for the agent;
    /// nil when the calendar isn't connected.
    func digest(pastDays: Int = 14, days: Int = 60, limit: Int = 80) -> String? {
        guard status == .connected else { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Double(pastDays) * 86_400),
            end: now.addingTimeInterval(Double(days) * 86_400), calendars: nil
        )
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        guard !events.isEmpty else { return "(no events)" }
        let day = DateFormatter()
        day.dateFormat = "EEE yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let lines = events.prefix(limit).map { event -> String in
            let title = String((event.title ?? "Busy").prefix(80))
            var when: String
            if event.isAllDay {
                // All-day events end at midnight after their last day.
                let last = event.endDate.addingTimeInterval(-1)
                when = Calendar.current.isDate(event.startDate, inSameDayAs: last)
                    ? "\(day.string(from: event.startDate)) all day"
                    : "\(day.string(from: event.startDate)) to \(day.string(from: last)) all day"
            } else {
                when = "\(day.string(from: event.startDate)) \(time.string(from: event.startDate))-\(time.string(from: event.endDate))"
            }
            let place = event.location.map { " @ \(String($0.prefix(60)))" } ?? ""
            return "- \(when) \(title)\(place) [\(event.calendar.title)]"
        }
        let more = events.count > limit ? "\n(\(events.count - limit) more not shown)" : ""
        return lines.joined(separator: "\n") + more
    }
}
