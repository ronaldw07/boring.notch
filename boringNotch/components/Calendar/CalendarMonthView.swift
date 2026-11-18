//
//  CalendarMonthView.swift
//  boringNotch
//
//  The month as a grid of days, like Google Calendar's: each day shows its
//  first events and how many more there are. Clicking a day opens it in the
//  day view.
//

import SwiftUI

struct CalendarMonthView: View {
    /// Whole weeks covering the month, from CalendarGrid.
    let days: [Date]
    /// The month being shown; days outside it are dimmed.
    let month: Date
    let events: [EventModel]
    /// Each day's forecast, by the start of the day.
    let weather: [Date: DayWeather]
    let onOpenDay: (Date) -> Void

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
                ForEach(dayEvents.prefix(Self.shownPerDay)) { event in
                    eventLine(event)
                }
                if dayEvents.count > Self.shownPerDay {
                    Text("+\(dayEvents.count - Self.shownPerDay) more")
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
