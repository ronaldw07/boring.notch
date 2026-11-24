//
//  EventHeadsUp.swift
//  boringNotch
//
//  A few minutes before a timed event, the closed notch shows its title and
//  how soon it starts for a few seconds. Skips all-day events, declined
//  invites, hidden calendars, and an open notch (you can already see it).
//

import Defaults
import Foundation
import SwiftUI

struct EventHeadsUpNotice: Equatable {
    let title: String
    let minutes: Int
    let color: NSColor
}

enum EventHeadsUpRule {
    /// How long before the start the heads-up comes.
    static let lead: TimeInterval = 5 * 60

    /// Starts within the lead, and hasn't started yet.
    static func isDue(start: Date, now: Date) -> Bool {
        let until = start.timeIntervalSince(now)
        return until > 0 && until <= lead
    }

    /// "in 5 min", rounded up so it never undersells the wait.
    static func minutes(until start: Date, now: Date) -> Int {
        max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
    }
}

@MainActor
final class EventHeadsUp {
    static let shared = EventHeadsUp()

    private static let checkEvery: Duration = .seconds(30)
    private static let showFor: Duration = .seconds(8)

    private var loop: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    /// Occurrences already announced, by id and start.
    private var announced = Set<String>()

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    private func check() async {
        guard Defaults[.eventHeadsUp] else { return }
        let now = Date()
        let upcoming = await CalendarManager.shared.events(from: now, to: now.addingTimeInterval(EventHeadsUpRule.lead))
        let due = upcoming.filter { event in
            event.type.isEvent && !event.isAllDay && event.attendance != .declined
                && EventHeadsUpRule.isDue(start: event.start, now: now)
                && !announced.contains(Self.key(event))
        }
        guard let next = due.min(by: { $0.start < $1.start }) else { return }
        due.forEach { announced.insert(Self.key($0)) }
        show(EventHeadsUpNotice(
            title: next.title,
            minutes: EventHeadsUpRule.minutes(until: next.start, now: now),
            color: next.calendar.color
        ))
    }

    private func show(_ notice: EventHeadsUpNotice) {
        let coordinator = BoringViewCoordinator.shared
        withAnimation(.smooth) { coordinator.eventHeadsUp = notice }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: Self.showFor)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { coordinator.eventHeadsUp = nil }
        }
    }

    private static func key(_ event: EventModel) -> String {
        "\(event.id)-\(event.start.timeIntervalSince1970)"
    }
}

/// Either side of the closed notch: the event's title on the left, how soon
/// on the right, the notch itself left black between them.
struct EventHeadsUpView: View {
    let notice: EventHeadsUpNotice
    let notchWidth: CGFloat

    private static let sideWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: notice.color))
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.sideWidth, alignment: .leading)
            .padding(.leading, 8)

            Rectangle()
                .fill(.black)
                .frame(width: notchWidth + 10)

            Text("in \(notice.minutes) min")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: Self.sideWidth, alignment: .trailing)
                .padding(.trailing, 8)
        }
    }
}
