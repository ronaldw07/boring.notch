//
//  WeatherManager.swift
//  boringNotch
//
//  The forecast for where the Mac is, from Open-Meteo (free, no account).
//  Asks for location once; refreshes at most every half hour, and only
//  when the calendar asks, so nothing runs with the notch closed.
//

import CoreLocation
import Foundation

@MainActor
final class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var forecast: WeatherForecast?

    private let locationManager = CLLocationManager()
    private var lastFetch: Date?
    private var isFetching = false

    private static let refreshInterval: TimeInterval = 30 * 60
    private static let forecastDays = 16
    private static let pastDays = 7
    private static let endpoint = "https://api.open-meteo.com/v1/forecast"

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Fetches unless the forecast is fresh. The first call asks for
    /// location; a refusal leaves the weather off.
    func refreshIfStale() {
        if let lastFetch, Date.now.timeIntervalSince(lastFetch) < Self.refreshInterval { return }
        guard !isFetching else { return }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            isFetching = true
            locationManager.requestLocation()
        default:
            break
        }
    }

    private func fetch(for location: CLLocation) async {
        defer { isFetching = false }
        let usesFahrenheit = Locale.current.measurementSystem == .us
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", location.coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", location.coordinate.longitude)),
            .init(name: "current", value: "temperature_2m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day,precipitation_probability"),
            .init(name: "temperature_unit", value: usesFahrenheit ? "fahrenheit" : "celsius"),
            .init(name: "timezone", value: TimeZone.current.identifier),
            .init(name: "forecast_days", value: String(Self.forecastDays)),
            // So the week's earlier days have weather too.
            .init(name: "past_days", value: String(Self.pastDays)),
        ]
        guard let url = components?.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("WeatherManager: forecast request failed: \(response)")
                return
            }
            forecast = try WeatherForecast.parse(data)
            lastFetch = .now
        } catch {
            NSLog("WeatherManager: couldn't load the forecast: \(error)")
        }
    }
}

extension WeatherManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if status == .authorized || status == .authorizedAlways {
                refreshIfStale()
            } else if status == .denied || status == .restricted {
                NSLog("WeatherManager: location not allowed; weather stays off")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in await fetch(for: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("WeatherManager: couldn't get a location: \(error)")
        Task { @MainActor in isFetching = false }
    }
}
