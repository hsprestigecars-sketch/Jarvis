import CoreLocation
import Foundation
import JarvisCore

/// Weather from Open-Meteo: free, no API key. A named place is looked up
/// with Open-Meteo's geocoder; with no place, JARVIS asks iPadOS for the
/// current location once (rounded to about 1 km before it is sent).
@MainActor
enum WeatherTools {
    static func register(in registry: ToolRegistry) throws {
        try registry.register(
            ToolSpec(
                name: "get_weather",
                description: "Current weather and a daily forecast (up to 7 days): conditions, high/low, chance of rain or snow, wind, sunrise and sunset. Omit 'place' for the iPad's current location.",
                category: .information, risk: .safe,
                inputSchema: Schema.object([
                    "place": Schema.string("City or town, optionally with region or country, e.g. 'Austin, TX'. Omit for the current location."),
                    "days": Schema.integer("Days of forecast including today, 1–7 (default 3)"),
                    "units": Schema.enumeration(TemperatureUnit.allCases.map(\.rawValue), "Temperature units (default: the user's region)"),
                ])
            )
        ) { args in
            let unit = args.optionalString("units").flatMap(TemperatureUnit.init(rawValue:)) ?? .default()
            let days = min(max(args.optionalInt("days") ?? 3, 1), OpenMeteo.maxDays)

            let place: WeatherPlace
            if let query = args.optionalString("place") {
                let (name, qualifiers) = OpenMeteo.splitQuery(query)
                let places = try OpenMeteo.parsePlaces(try await download(OpenMeteo.geocodingURL(for: name)))
                guard let match = OpenMeteo.bestMatch(places, qualifiers: qualifiers) else {
                    return ToolOutput.error("Couldn't find a place called '\(query)'. Try adding the country, e.g. 'Paris, France'.")
                }
                place = match
            } else {
                let coordinate = try await CurrentLocation.fetch()
                place = WeatherPlace(name: "your current location", latitude: coordinate.latitude, longitude: coordinate.longitude)
            }

            let data = try await download(OpenMeteo.forecastURL(latitude: place.latitude, longitude: place.longitude, days: days, unit: unit))
            let forecast: WeatherForecast
            do {
                forecast = try OpenMeteo.parseForecast(data, unit: unit)
            } catch {
                throw ToolError.failed("The weather service sent a reply JARVIS couldn't read.")
            }
            let now = forecast.current
            return ToolOutput(
                OpenMeteo.report(place: place.displayName, forecast: forecast),
                summary: "\(Int(now.temperature.rounded()))\(unit.symbol), \(OpenMeteo.describe(code: now.code)) — \(place.name)"
            )
        }
    }

    private static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ToolError.failed("Couldn't reach the weather service. Check the internet connection.")
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw ToolError.unavailable("The weather service isn't responding right now. Try again in a moment.")
        }
        return data
    }
}

/// Asks iPadOS for the current location once, at about 1 km accuracy, and
/// only while JARVIS is open ("When In Use").
@MainActor
final class CurrentLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorization: CheckedContinuation<Void, Never>?
    private var location: CheckedContinuation<CLLocationCoordinate2D, Error>?

    static func fetch() async throws -> CLLocationCoordinate2D {
        let finder = CurrentLocation()
        return try await finder.locate()
    }

    private func locate() async throws -> CLLocationCoordinate2D {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorization = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            throw ToolError.permissionDenied("JARVIS can't use your location. Allow it in Settings › Privacy & Security › Location Services › JARVIS, or name a place.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            location = continuation
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self.finish(.failure(ToolError.unavailable("The iPad couldn't find its location in time. Try again, or name a place.")))
            }
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        location?.resume(with: result)
        location = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            self.authorization?.resume()
            self.authorization = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in self.finish(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(.failure(ToolError.unavailable("The iPad couldn't work out where it is. Try again, or name a place.")))
        }
    }
}
