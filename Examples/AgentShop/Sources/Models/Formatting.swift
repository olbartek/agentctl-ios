import Foundation

/// Formats integer cents as dollars without `Locale`, so output is identical on every machine: `5980` → `$59.80`.
public func formatCents(_ cents: Int) -> String {
  let sign = cents < 0 ? "-" : ""
  let magnitude = cents.magnitude
  let fraction = magnitude % 100
  return "\(sign)$\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
}

private let dayStyle = Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()

/// Formats a date as `yyyy-MM-dd` in UTC.
public func formatDay(_ date: Date) -> String {
  date.formatted(dayStyle)
}

/// Parses `yyyy-MM-dd` as midnight UTC. Traps on malformed input; meant for seed data and tests.
public func day(_ string: String) -> Date {
  guard let date = try? dayStyle.parse(string) else {
    preconditionFailure("Invalid day literal: \(string)")
  }
  return date
}
