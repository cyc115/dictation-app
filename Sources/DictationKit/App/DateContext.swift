import SwiftUI

/// What date text depends on: the Mac's region, clock and time zone settings. Views read it from the
/// environment, so snapshot tests can fix it (`HostedView`) and pass whatever those settings are.
struct DateContext {
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent
    /// In `timeZone`, for "Today" / "Yesterday".
    var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }

    func string(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style.locale(locale)
        style.timeZone = timeZone
        style.calendar = calendar
        return date.formatted(style)
    }
}

extension EnvironmentValues {
    @Entry var dateContext = DateContext()
}
