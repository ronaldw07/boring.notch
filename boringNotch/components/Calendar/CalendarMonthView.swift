//
//  CalendarMonthView.swift
//  boringNotch
//
//  The month as a grid of days, like Google Calendar's: each day shows its
//  first events and tasks and how many more there are. Clicking a day opens
//  it in the day view; a task's circle ticks it off.
//

import SwiftUI

struct CalendarMonthView: View {
    /// Whole weeks covering the month, from CalendarGrid.
    let days: [Date]
    /// The month being shown; days outside it are dimmed.
    let month: Date
    let events: [EventModel]
    /// Google tasks due on the days shown.
    let tasks: [GoogleTask]
    /// Each day's forecast, by the start of the day.
    let weather: [Date: DayWeather]
    let onOpenDay: (Date) -> Void
    let onToggleTask: (GoogleTask) -> Void
    let onOpenTask: (GoogleTask) -> Void
    /// A day the pointer went into (true) or left (false), for pasting.
    let onHoverDay: (Date, Bool) -> Void

    /// One line in a day: all-day events first, then tasks (which have no
    /// time), then timed events, the order Google uses.
    private enum Line: Identifiable {
        case event(EventModel)
        case task(GoogleTask)

        var id: String {
            switch self {
            case .event(let event): "e-\(event.id)-\(event.start.timeIntervalSince1970)"
            case .task(let task): "t-\(task.id)"
            }
        }
    }

    private static let shownPerDay = 2
    private static let weekdayRowHeight: CGFloat = 14

    var body: some View {
        let weeks = stride(from: 0, to: days.count, by: CalendarGrid.daysInWeek).map {
            Array(days[$0 ..< min($0 + CalendarGrid.daysInWeek, days.count)])
        }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(CalendarGrid.daysInWeek), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.weekdayRowHeight)
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        cell(day)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let dayEvents = CalendarGrid.events(on: day, from: events)
        let dayTasks = tasks.filter { calendar.isDate($0.due, inSameDayAs: day) }
        let lines: [Line] = dayEvents.filter(\.isAllDay).map(Line.event)
            + dayTasks.map(Line.task)
            + dayEvents.filter { !$0.isAllDay }.map(Line.event)
        return Button { onOpenDay(day) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text("\(calendar.component(.day, from: day))")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isToday ? .white : (inMonth ? .white.opacity(0.85) : .gray.opacity(0.6)))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))
                    Spacer(minLength: 0)
                    if let dayWeather = weather[calendar.startOfDay(for: day)] {
                        Image(systemName: dayWeather.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 9))
                        Text("\(dayWeather.high)°")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                }
                ForEach(lines.prefix(Self.shownPerDay)) { line in
                    switch line {
                    case .event(let event): eventLine(event)
                    case .task(let task): taskLine(task)
                    }
                }
                if lines.count > Self.shownPerDay {
                    Text("+\(lines.count - Self.shownPerDay) more")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.gray)
                }
                Spacer(minLength: 0)
            }
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(Rectangle().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .opacity(inMonth ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(day.formatted(date: .complete, time: .omitted))
        .onHover { onHoverDay(day, $0) }
    }

    private func taskLine(_ task: GoogleTask) -> some View {
        HStack(spacing: 3) {
            Button { onToggleTask(task) } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(task.isCompleted ? .green : .gray)
            }
            .buttonStyle(.plain)
            .help(task.isCompleted ? "Mark not done" : "Mark done")
            Button { onOpenTask(task) } label: {
                Text(task.title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(task.isCompleted ? .gray : .white.opacity(0.85))
                    .strikethrough(task.isCompleted)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Edit task")
        }
    }

    private func eventLine(_ event: EventModel) -> some View {
        let color = Color(nsColor: event.calendar.color)
        return HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 2, height: 9)
            Text(event.title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, event.isAllDay ? 3 : 0)
        .background(event.isAllDay ? RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.25)) : nil)
    }
}
