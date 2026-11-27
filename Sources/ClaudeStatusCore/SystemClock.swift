import Darwin
import Foundation

/// Boot and wake times from the kernel (`kern.boottime`, `kern.waketime`). No permission is
/// needed. Silence while the Mac was asleep is not evidence about a session: Claude Code was
/// suspended too, so staleness is measured from the later of the last event and the last wake.
public enum SystemClock {
    static func readTimeval(_ name: String) -> Double? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname(name, &tv, &size, nil, 0) == 0, size == MemoryLayout<timeval>.size, tv.tv_sec > 0 else {
            return nil
        }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// Most recent wake from sleep since boot (nil if the Mac has not slept).
    public static func lastWake() -> Double? {
        guard let w = readTimeval("kern.waketime") else { return nil }
        if let b = bootTime(), w < b { return nil }
        return w
    }

    public static func bootTime() -> Double? { readTimeval("kern.boottime") }

    /// The later of an app-observed wake and the kernel's wake time.
    public static func effectiveWake(observed: Double?) -> Double? {
        switch (observed, lastWake()) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }
}
