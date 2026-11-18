//
//  WeatherForecast.swift
//  boringNotch
//
//  The calendar header's weather, read from Open-Meteo's forecast: each
//  day's icon, high and low, the temperature now, and the first hour today
//  that rain is likely.
//

import Foundation

struct DayWeather: Equatable {
    let symbol: String
    let high: Int
    let low: Int
    /// Highest chance of rain in the day, 0–100.
    let rainChance: Int
}

struct HourWeather: Equatable {
    let time: Date
    let symbol: String
    let temperature: Int
    let rainChance: Int
}

struct WeatherForecast: Equatable {
    /// Keyed by the start of each local day.
    let days: [Date: DayWeather]
    let currentTemperature: Int?
    /// "Rain at 4pm", or nil when no hour left today looks wet.
    let rainNote: String?
    /// This hour and the ones after it, for the weather card.
    let hours: [HourWeather]

    /// Rain counts as likely from this chance up.
    static let rainLikely = 50
    static let hoursShown = 12

    /// The shape of Open-Meteo's reply, only the parts used here.
    struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
        }
        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int?]
        }
        struct Hourly: Decodable {
            let time: [String]
            let precipitation_probability: [Int?]
            let temperature_2m: [Double]?
            let weather_code: [Int]?
            let is_day: [Int]?
        }
        let current: Current?
        let daily: Daily
        let hourly: Hourly?
    }

    /// Open-Meteo gives local times without a zone, e.g. "2026-11-17" and
    /// "2026-11-17T16:00", in the forecast place's zone, taken here as the Mac's.
    static func parse(_ data: Data, now: Date = .now, calendar: Calendar = .current) throws -> WeatherForecast {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let daily = response.daily
        let count = [daily.time.count, daily.weather_code.count, daily.temperature_2m_max.count,
                     daily.temperature_2m_min.count, daily.precipitation_probability_max.count].min() ?? 0

        let dayFormat = formatter("yyyy-MM-dd", calendar: calendar)
        var days: [Date: DayWeather] = [:]
        for index in 0 ..< count {
            guard let date = dayFormat.date(from: daily.time[index]) else { continue }
            days[calendar.startOfDay(for: date)] = DayWeather(
                symbol: symbol(for: daily.weather_code[index]),
                high: Int(daily.temperature_2m_max[index].rounded()),
                low: Int(daily.temperature_2m_min[index].rounded()),
                rainChance: daily.precipitation_probability_max[index] ?? 0
            )
        }

        return WeatherForecast(
            days: days,
            currentTemperature: response.current.map { Int($0.temperature_2m.rounded()) },
            rainNote: response.hourly.flatMap { rainNote($0, now: now, calendar: calendar) },
            hours: response.hourly.map { hours($0, now: now, calendar: calendar) } ?? []
        )
    }

    /// The next hours from this one, skipping any missing a temperature.
    private static func hours(_ hourly: Response.Hourly, now: Date, calendar: Calendar) -> [HourWeather] {
        guard let temperatures = hourly.temperature_2m, let codes = hourly.weather_code else { return [] }
        let hourFormat = formatter("yyyy-MM-dd'T'HH:mm", calendar: calendar)
        let thisHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var result: [HourWeather] = []
        for index in hourly.time.indices where index < temperatures.count && index < codes.count {
            guard let time = hourFormat.date(from: hourly.time[index]), time >= thisHour else { continue }
            let isDay = hourly.is_day.map { index < $0.count ? $0[index] == 1 : true } ?? true
            result.append(HourWeather(
                time: time,
                symbol: symbol(for: codes[index], isDay: isDay),
                temperature: Int(temperatures[index].rounded()),
                rainChance: index < hourly.precipitation_probability.count ? hourly.precipitation_probability[index] ?? 0 : 0
            ))
            if result.count == hoursShown { break }
        }
        return result
    }

    /// The first hour from now until midnight with rain likely.
    private static func rainNote(_ hourly: Response.Hourly, now: Date, calendar: Calendar) -> String? {
        let hourFormat = formatter("yyyy-MM-dd'T'HH:mm", calendar: calendar)
        let thisHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        for (time, chance) in zip(hourly.time, hourly.precipitation_probability) {
            guard let date = hourFormat.date(from: time), date >= thisHour,
                  calendar.isDate(date, inSameDayAs: now) else { continue }
            if (chance ?? 0) >= rainLikely {
                return date <= now ? "Rain now" : "Rain at \(hourText(date, calendar: calendar))"
            }
        }
        return nil
    }

    /// "4pm", "12am".
    static func hourText(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let twelveHour = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelveHour)\(hour < 12 ? "am" : "pm")"
    }

    /// An SF Symbol for a WMO weather code, as Open-Meteo reports them.
    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51 ... 57: "cloud.drizzle.fill"
        case 61 ... 67, 80 ... 82: "cloud.rain.fill"
        case 71 ... 77, 85, 86: "cloud.snow.fill"
        case 95 ... 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
