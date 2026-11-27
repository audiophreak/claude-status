import Foundation

/// Minimal five-field cron expression (`minute hour day-of-month month day-of-week`), used
/// only to compute when a documented `session_crons` one-shot wakeup will fire, so the
/// dashboard can show "continues at 14:05". Supports `*`, numbers, `a-b`, lists and `/step`.
/// Expressions it does not understand yield nil (shown as "scheduled", without a time).
public struct CronSchedule: Equatable, Sendable {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    public let daysOfWeek: Set<Int>   // 0 = Sunday
    let domRestricted: Bool
    let dowRestricted: Bool

    public init?(_ expression: String) {
        let f = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard expression.utf8.count <= 128, f.count == 5 else { return nil }
        guard let mi = CronSchedule.field(f[0], 0, 59), let h = CronSchedule.field(f[1], 0, 23),
              let dom = CronSchedule.field(f[2], 1, 31), let mo = CronSchedule.field(f[3], 1, 12),
              var dow = CronSchedule.field(f[4], 0, 7) else { return nil }
        if dow.contains(7) { dow.remove(7); dow.insert(0) }
        minutes = mi; hours = h; daysOfMonth = dom; months = mo; daysOfWeek = dow
        domRestricted = f[2] != "*"
        dowRestricted = f[4] != "*"
    }

    static func field(_ s: String, _ lo: Int, _ hi: Int) -> Set<Int>? {
        var out = Set<Int>()
        for part in s.split(separator: ",", omittingEmptySubsequences: false) {
            var range = Substring(part)
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                guard let st = Int(part[part.index(after: slash)...]), st > 0, st <= hi else { return nil }
                step = st
                range = part[..<slash]
            }
            var a = lo, b = hi
            if range == "*" {
                // full range
            } else if let dash = range.firstIndex(of: "-") {
                guard let x = Int(range[..<dash]), let y = Int(range[range.index(after: dash)...]) else { return nil }
                a = x; b = y
            } else {
                guard let x = Int(range) else { return nil }
                a = x; b = part.contains("/") ? hi : x
            }
            guard a >= lo, b <= hi, a <= b else { return nil }
            out.formUnion(stride(from: a, through: b, by: step))
        }
        return out.isEmpty ? nil : out
    }

    func dayMatches(dom: Int, dow: Int) -> Bool {
        // Standard cron: when both day fields are restricted, either may match.
        if domRestricted && dowRestricted { return daysOfMonth.contains(dom) || daysOfWeek.contains(dow) }
        return daysOfMonth.contains(dom) && daysOfWeek.contains(dow)
    }

    /// First firing time strictly after `after`, searching at most `maxDays` ahead.
    public func next(after: Date, calendar: Calendar = .current, maxDays: Int = 400) -> Date? {
        let sortedH = hours.sorted(), sortedM = minutes.sorted()
        let startOfDay = calendar.startOfDay(for: after)
        for d in 0...maxDays {
            guard let day = calendar.date(byAdding: .day, value: d, to: startOfDay) else { return nil }
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            guard let mo = c.month, let dom = c.day, let wd = c.weekday, months.contains(mo),
                  dayMatches(dom: dom, dow: wd - 1) else { continue }
            for h in sortedH {
                for m in sortedM {
                    var dc = DateComponents()
                    dc.year = c.year; dc.month = mo; dc.day = dom; dc.hour = h; dc.minute = m
                    guard let t = calendar.date(from: dc), t > after else { continue }
                    // Skip times that do not exist (DST gap): the calendar moves them.
                    if calendar.component(.hour, from: t) != h { continue }
                    return t
                }
            }
        }
        return nil
    }
}
