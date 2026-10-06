import Foundation

/// Weather from Open-Meteo (open-meteo.com): free, no API key and no account.
/// This file builds the requests and turns the replies into a short report;
/// the app does the networking and the location lookup.
public enum TemperatureUnit: String, Sendable, CaseIterable {
    case celsius, fahrenheit

    public var symbol: String { self == .celsius ? "°C" : "°F" }
    public var windUnit: String { self == .celsius ? "km/h" : "mph" }

    /// Fahrenheit for the US measurement system, Celsius everywhere else.
    public static func `default`(for locale: Locale = .current) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }
}

public struct WeatherPlace: Equatable, Sendable {
    public var name: String
    public var region: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double

    public init(name: String, region: String? = nil, country: String? = nil, latitude: Double, longitude: Double) {
        self.name = name
        self.region = region
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "Paris, Île-de-France, France"
    public var displayName: String {
        [name, region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public struct WeatherForecast: Equatable, Sendable {
    public struct Current: Equatable, Sendable {
        public var time: String
        public var temperature: Double
        public var feelsLike: Double?
        public var humidity: Double?
        public var windSpeed: Double?
        public var code: Int
    }

    public struct Day: Equatable, Sendable {
        /// yyyy-MM-dd in the place's own time zone.
        public var date: String
        public var code: Int
        public var high: Double
        public var low: Double
        public var precipitationChance: Double?
        public var sunrise: String?
        public var sunset: String?
    }

    public var current: Current
    public var days: [Day]
    public var unit: TemperatureUnit
}

public enum OpenMeteo {
    public static let maxDays = 7

    public static func geocodingURL(for name: String) -> URL {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "10"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components.url!
    }

    /// Coordinates are rounded to two decimals (about 1 km) so the exact
    /// position never leaves the iPad.
    public static func forecastURL(latitude: Double, longitude: Double, days: Int, unit: TemperatureUnit) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.2f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.2f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(min(max(days, 1), maxDays))),
            URLQueryItem(name: "temperature_unit", value: unit.rawValue),
            URLQueryItem(name: "wind_speed_unit", value: unit == .celsius ? "kmh" : "mph"),
        ]
        return components.url!
    }

    /// The geocoder only understands a bare place name, so "Paris, Texas" is
    /// searched as "Paris" and the rest is used to pick the right match.
    public static func splitQuery(_ query: String) -> (name: String, qualifiers: [String]) {
        let parts = query.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (parts.first ?? query.trimmingCharacters(in: .whitespaces), Array(parts.dropFirst()))
    }

    public static func parsePlaces(_ data: Data) throws -> [WeatherPlace] {
        struct Response: Decodable {
            struct Result: Decodable {
                var name: String
                var latitude: Double
                var longitude: Double
                var country: String?
                var country_code: String?
                var admin1: String?
            }
            var results: [Result]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.results ?? []).map {
            WeatherPlace(name: $0.name, region: $0.admin1, country: $0.country, latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    /// The first place whose region or country matches every qualifier
    /// ("TX" or "Texas", "US" or "United States"), else the top result.
    public static func bestMatch(_ places: [WeatherPlace], qualifiers: [String]) -> WeatherPlace? {
        guard !qualifiers.isEmpty else { return places.first }
        func matches(_ place: WeatherPlace, _ qualifier: String) -> Bool {
            let q = qualifier.lowercased()
            let fields = [place.region, place.country].compactMap { $0?.lowercased() }
            if fields.contains(where: { $0 == q || (q.count >= 3 && $0.hasPrefix(q)) }) { return true }
            if let abbreviation = usStates[q.uppercased()], place.region?.lowercased() == abbreviation.lowercased() { return true }
            if ["us", "usa", "united states of america"].contains(q), place.country == "United States" { return true }
            if ["uk", "britain", "great britain"].contains(q), place.country == "United Kingdom" { return true }
            return false
        }
        return places.first { place in qualifiers.allSatisfy { matches(place, $0) } } ?? places.first
    }

    public static func parseForecast(_ data: Data, unit: TemperatureUnit) throws -> WeatherForecast {
        struct Response: Decodable {
            struct Current: Decodable {
                var time: String
                var temperature_2m: Double
                var apparent_temperature: Double?
                var relative_humidity_2m: Double?
                var wind_speed_10m: Double?
                var weather_code: Int
            }
            struct Daily: Decodable {
                var time: [String]
                var weather_code: [Int?]
                var temperature_2m_max: [Double?]
                var temperature_2m_min: [Double?]
                var precipitation_probability_max: [Double?]?
                var sunrise: [String?]?
                var sunset: [String?]?
            }
            var current: Current
            var daily: Daily
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let daily = response.daily
        let days: [WeatherForecast.Day] = daily.time.indices.compactMap { i in
            guard let high = daily.temperature_2m_max[safe: i] ?? nil, let low = daily.temperature_2m_min[safe: i] ?? nil else { return nil }
            return WeatherForecast.Day(
                date: daily.time[i],
                code: (daily.weather_code[safe: i] ?? nil) ?? 0,
                high: high, low: low,
                precipitationChance: daily.precipitation_probability_max?[safe: i] ?? nil,
                sunrise: daily.sunrise?[safe: i] ?? nil,
                sunset: daily.sunset?[safe: i] ?? nil
            )
        }
        let current = response.current
        return WeatherForecast(
            current: .init(
                time: current.time, temperature: current.temperature_2m, feelsLike: current.apparent_temperature,
                humidity: current.relative_humidity_2m, windSpeed: current.wind_speed_10m, code: current.weather_code
            ),
            days: days, unit: unit
        )
    }

    /// WMO weather interpretation codes, as used by Open-Meteo.
    public static func describe(code: Int) -> String {
        switch code {
        case 0: "clear sky"
        case 1: "mainly clear"
        case 2: "partly cloudy"
        case 3: "overcast"
        case 45, 48: "fog"
        case 51, 53, 55: "drizzle"
        case 56, 57: "freezing drizzle"
        case 61: "light rain"
        case 63: "rain"
        case 65: "heavy rain"
        case 66, 67: "freezing rain"
        case 71: "light snow"
        case 73: "snow"
        case 75: "heavy snow"
        case 77: "snow grains"
        case 80, 81: "rain showers"
        case 82: "violent rain showers"
        case 85, 86: "snow showers"
        case 95: "thunderstorm"
        case 96, 99: "thunderstorm with hail"
        default: "unknown conditions"
        }
    }

    /// The text given to the model: current conditions, then one line per day.
    public static func report(place: String, forecast: WeatherForecast) -> String {
        let unit = forecast.unit
        func temp(_ value: Double) -> String { "\(Int(value.rounded()))\(unit.symbol)" }
        func clock(_ iso: String?) -> String? { iso.flatMap { $0.split(separator: "T").last.map(String.init) } }

        let now = forecast.current
        var currentLine = "Now (\(now.time) local): \(temp(now.temperature)), \(describe(code: now.code))"
        if let feelsLike = now.feelsLike { currentLine += ", feels like \(temp(feelsLike))" }
        if let humidity = now.humidity { currentLine += ", humidity \(Int(humidity.rounded()))%" }
        if let wind = now.windSpeed { currentLine += ", wind \(Int(wind.rounded())) \(unit.windUnit)" }

        var lines = ["Weather for \(place)", currentLine]
        for day in forecast.days {
            var line = "- \(day.date): \(describe(code: day.code)), high \(temp(day.high)), low \(temp(day.low))"
            if let chance = day.precipitationChance { line += ", \(Int(chance.rounded()))% chance of precipitation" }
            if let sunrise = clock(day.sunrise), let sunset = clock(day.sunset) { line += ", sunrise \(sunrise), sunset \(sunset)" }
            lines.append(line)
        }
        lines.append("Source: Open-Meteo")
        return lines.joined(separator: "\n")
    }

    static let usStates: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
        "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
        "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
        "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming", "DC": "District of Columbia",
    ]
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
