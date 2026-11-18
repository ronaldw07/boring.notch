//
//  WeatherCard.swift
//  boringNotch
//
//  Opened from the weather in the calendar header: the next hours and the
//  next days. Escape or a click outside closes it.
//

import SwiftUI

struct WeatherCard: View {
    let forecast: WeatherForecast
    let onClose: () -> Void

    @State private var keyMonitor: Any?

    private static let escapeKey: UInt16 = 53

    private static let daysShown = 7
    /// Rain chances under this aren't worth showing.
    private static let rainShownFrom = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title
            HStack(spacing: 0) {
                ForEach(forecast.hours, id: \.time) { hour in
                    column(
                        label: hour.time == forecast.hours.first?.time ? "Now" : WeatherForecast.hourText(hour.time),
                        symbol: hour.symbol,
                        value: "\(hour.temperature)°",
                        rainChance: hour.rainChance
                    )
                }
            }
            Divider().overlay(.white.opacity(0.1))
            HStack(spacing: 0) {
                ForEach(upcomingDays, id: \.0) { date, day in
                    column(
                        label: Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.abbreviated)),
                        symbol: day.symbol,
                        value: "\(day.high)°/\(day.low)°",
                        rainChance: day.rainChance
                    )
                }
            }
        }
        .padding(12)
        .frame(width: 460, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(CardBackground())
        .onAppear {
            NotchKeyboardFocus.begin(holdsNotchOpen: false)
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key in
                guard key.keyCode == Self.escapeKey else { return key }
                onClose()
                return nil
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            NotchKeyboardFocus.end()
        }
    }

    /// "Weather · 62° now · Rain at 4pm".
    private var title: some View {
        HStack(spacing: 6) {
            Text("Weather")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            if let now = forecast.currentTemperature {
                Text("\(now)° now")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let rain = forecast.rainNote {
                Text(rain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.cyan)
            }
        }
    }

    /// Today and the days after it that the forecast has.
    private var upcomingDays: [(Date, DayWeather)] {
        let today = Calendar.current.startOfDay(for: .now)
        return forecast.days
            .filter { $0.key >= today }
            .sorted { $0.key < $1.key }
            .prefix(Self.daysShown)
            .map { ($0.key, $0.value) }
    }

    private func column(label: String, symbol: String, value: String, rainChance: Int) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.gray)
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 12))
                .frame(height: 14)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
            Text(rainChance >= Self.rainShownFrom ? "\(rainChance)%" : " ")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.cyan)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}
