import CoreLocation
import Foundation
import OSLog
import Ontology
import WeatherKit

private let log = Logger.service("weather")

final class WeatherService: Service {
    static let shared = WeatherService()

    private let weatherService = WeatherKit.WeatherService.shared

    private static let location = ToolArgument.coordinate().map {
        CLLocation(latitude: $0.latitude, longitude: $0.longitude)
    }
    private static let days = ToolArgument.integer(
        "days",
        description: "Number of forecast days (max 10)",
        default: 7,
        in: 1 ... 10
    )
    private static let hours = ToolArgument.integer(
        "hours",
        description: "Number of hourly forecasts to return, starting from the current hour",
        default: 24,
        in: 1 ... 240
    )
    private static let minutes = ToolArgument.integer(
        "minutes",
        description: "Number of one-minute entries to return, starting now",
        default: 60,
        in: 1 ... 120
    )

    var tools: [Tool] {
        Tool(
            name: "weather_current",
            description:
                "Get current weather for a location",
            arguments: [Self.location],
            annotations: .init(
                title: "Get Current Weather",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(arguments)
            let currentWeather = try await self.weatherService.weather(
                for: location,
                including: .current
            )

            return WeatherConditions(currentWeather)
        }

        Tool(
            name: "weather_daily",
            description: "Get daily weather forecast for a location",
            arguments: [Self.location, Self.days],
            annotations: .init(
                title: "Get Daily Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(arguments)
            let days = try Self.days(arguments)

            let dailyForecast = try await self.weatherService.weather(
                for: location,
                including: .daily
            )

            return dailyForecast.prefix(days).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_hourly",
            description: "Get hourly weather forecast for a location",
            arguments: [Self.location, Self.hours],
            annotations: .init(
                title: "Get Hourly Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(arguments)
            let hours = try Self.hours(arguments)

            let hourlyForecasts = try await self.weatherService.weather(
                for: location,
                including: .hourly
            )

            return hourlyForecasts.prefix(hours).map { WeatherForecast($0) }
        }

        Tool(
            name: "weather_minute",
            description:
                "Get a minute-by-minute forecast for a location. Not available in every region.",
            arguments: [Self.location, Self.minutes],
            annotations: .init(
                title: "Get Minute-by-Minute Forecast",
                readOnlyHint: true,
                openWorldHint: true
            )
        ) { arguments in
            let location = try Self.location(arguments)
            let minutes = try Self.minutes(arguments)

            guard
                let minuteByMinuteForecast = try await self.weatherService.weather(
                    for: location,
                    including: .minute
                )
            else {
                throw ToolFailure("No minute-by-minute forecast available")
            }

            return minuteByMinuteForecast.prefix(minutes).map { WeatherForecast($0) }
        }
    }
}
