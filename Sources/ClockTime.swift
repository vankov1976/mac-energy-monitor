import Foundation

/// Clock times everywhere in the app, as macOS writes them: with the 24-hour clock always two hour digits (03:56,
/// as macOS does; the app's own formats used to give 3:56), with the 12-hour clock as usual (3:56 AM).
/// Date format and month names follow the Mac's settings.
enum Clock {
    private static var hm: Date.FormatStyle {
        let h24 = (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("H")   // "HH 'Uhr'" vs "h a"
        return Date.FormatStyle().hour(h24 ? .twoDigits(amPM: .abbreviated) : .defaultDigits(amPM: .abbreviated)).minute(.twoDigits)
    }
    /// "03:56" (or "3:56 AM").
    static func time(_ d: Date) -> String { d.formatted(hm) }
    /// "21. Nov., 03:56" (day and month as the Mac writes them).
    static func dayTime(_ d: Date) -> String { d.formatted(hm.day().month(.abbreviated)) }
    /// "21. Nov. 2026, 03:56" in place of formatted(date: .abbreviated, time: .shortened).
    static func dateTime(_ d: Date) -> String { d.formatted(hm.day().month(.abbreviated).year()) }
}
