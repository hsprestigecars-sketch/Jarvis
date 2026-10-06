import XCTest
@testable import JarvisCore

final class WeatherTests: XCTestCase {
    private let forecastJSON = """
    {"latitude":30.27,"longitude":-97.74,
     "current":{"time":"2026-10-06T14:00","interval":900,"temperature_2m":84.6,"apparent_temperature":88.2,
                "relative_humidity_2m":55,"weather_code":2,"wind_speed_10m":9.4},
     "daily":{"time":["2026-10-06","2026-10-07"],
              "weather_code":[2,61],
              "temperature_2m_max":[88.1,79.5],
              "temperature_2m_min":[70.2,null],
              "precipitation_probability_max":[10,null],
              "sunrise":["2026-10-06T07:28","2026-10-07T07:29"],
              "sunset":["2026-10-06T19:12","2026-10-07T19:11"]}}
    """

    func testParsesForecastAndSkipsIncompleteDays() throws {
        let forecast = try OpenMeteo.parseForecast(Data(forecastJSON.utf8), unit: .fahrenheit)
        XCTAssertEqual(forecast.current.temperature, 84.6)
        XCTAssertEqual(forecast.current.code, 2)
        XCTAssertEqual(forecast.days.count, 1, "a day with a missing low is dropped")
        XCTAssertEqual(forecast.days.first?.precipitationChance, 10)
    }

    func testReport() throws {
        let forecast = try OpenMeteo.parseForecast(Data(forecastJSON.utf8), unit: .fahrenheit)
        let report = OpenMeteo.report(place: "Austin, Texas, United States", forecast: forecast)
        XCTAssertTrue(report.contains("Weather for Austin, Texas, United States"))
        XCTAssertTrue(report.contains("85°F, partly cloudy, feels like 88°F, humidity 55%, wind 9 mph"))
        XCTAssertTrue(report.contains("- 2026-10-06: partly cloudy, high 88°F, low 70°F, 10% chance of precipitation, sunrise 07:28, sunset 19:12"))
        XCTAssertTrue(report.hasSuffix("Source: Open-Meteo"))
    }

    func testForecastURLRoundsCoordinatesAndClampsDays() throws {
        let url = OpenMeteo.forecastURL(latitude: 30.267153, longitude: -97.743061, days: 30, unit: .celsius)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(value("latitude"), "30.27")
        XCTAssertEqual(value("longitude"), "-97.74")
        XCTAssertEqual(value("forecast_days"), "7")
        XCTAssertEqual(value("temperature_unit"), "celsius")
        XCTAssertEqual(value("wind_speed_unit"), "kmh")
    }

    func testPlaceLookupPicksQualifiedMatch() throws {
        let json = """
        {"results":[
          {"name":"Paris","latitude":48.85,"longitude":2.35,"country":"France","admin1":"Île-de-France"},
          {"name":"Paris","latitude":33.66,"longitude":-95.56,"country":"United States","admin1":"Texas"},
          {"name":"Paris","latitude":39.61,"longitude":-87.70,"country":"United States","admin1":"Illinois"}
        ]}
        """
        let places = try OpenMeteo.parsePlaces(Data(json.utf8))
        XCTAssertEqual(places.count, 3)

        let (name, qualifiers) = OpenMeteo.splitQuery(" Paris, TX ")
        XCTAssertEqual(name, "Paris")
        XCTAssertEqual(qualifiers, ["TX"])
        XCTAssertEqual(OpenMeteo.bestMatch(places, qualifiers: qualifiers)?.region, "Texas")
        XCTAssertEqual(OpenMeteo.bestMatch(places, qualifiers: ["Illinois", "USA"])?.region, "Illinois")
        XCTAssertEqual(OpenMeteo.bestMatch(places, qualifiers: [])?.country, "France")
        XCTAssertEqual(OpenMeteo.bestMatch(places, qualifiers: ["Nowhere"])?.country, "France", "falls back to the top result")
        XCTAssertEqual(places[1].displayName, "Paris, Texas, United States")
    }

    func testNoPlaceFound() throws {
        XCTAssertEqual(try OpenMeteo.parsePlaces(Data(#"{"generationtime_ms":0.5}"#.utf8)), [])
    }

    func testWeatherCodes() {
        XCTAssertEqual(OpenMeteo.describe(code: 0), "clear sky")
        XCTAssertEqual(OpenMeteo.describe(code: 95), "thunderstorm")
        XCTAssertEqual(OpenMeteo.describe(code: 1234), "unknown conditions")
    }

    func testDefaultUnit() {
        XCTAssertEqual(TemperatureUnit.default(for: Locale(identifier: "en_US")), .fahrenheit)
        XCTAssertEqual(TemperatureUnit.default(for: Locale(identifier: "en_GB")), .celsius)
        XCTAssertEqual(TemperatureUnit.default(for: Locale(identifier: "fr_FR")), .celsius)
    }
}

final class TimerTextTests: XCTestCase {
    func testTotalSeconds() {
        XCTAssertEqual(TimerText.totalSeconds(hours: 1, minutes: 30, seconds: nil), 5400)
        XCTAssertEqual(TimerText.totalSeconds(hours: nil, minutes: nil, seconds: 45), 45)
        XCTAssertEqual(TimerText.totalSeconds(hours: nil, minutes: nil, seconds: nil), 0)
    }

    func testDuration() {
        XCTAssertEqual(TimerText.duration(45), "45 s")
        XCTAssertEqual(TimerText.duration(600), "10 min")
        XCTAssertEqual(TimerText.duration(150), "2 min 30 s")
        XCTAssertEqual(TimerText.duration(3900), "1 h 5 min")
        XCTAssertEqual(TimerText.duration(0), "0 s")
        XCTAssertEqual(TimerText.duration(-5), "0 s")
    }

    func testLabelMatching() {
        XCTAssertTrue(TimerText.label("Pasta water", matches: "pasta"))
        XCTAssertTrue(TimerText.label("Crème brûlée", matches: "creme"))
        XCTAssertFalse(TimerText.label("Pasta", matches: "laundry"))
        XCTAssertFalse(TimerText.label(nil, matches: "pasta"))
        XCTAssertFalse(TimerText.label("Pasta", matches: "  "))
    }

    func testAnnouncement() {
        XCTAssertEqual(TimerText.finishedAnnouncement(label: "pasta"), "Timer done: pasta.")
        XCTAssertEqual(TimerText.finishedAnnouncement(label: nil), "Your timer is done.")
        XCTAssertEqual(TimerText.finishedAnnouncement(label: " "), "Your timer is done.")
    }
}
