import Foundation
import Testing

@testable import AgentMonitorCore

/// Builds an instant from UTC components, so tests never depend on the machine's zone.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day
    components.hour = hour; components.minute = minute; components.second = second
    components.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: components)!
}

@Suite("procStart parsing")
struct ProcStartParserTests {

    /// Real `procStart` of pid 27435 on the machine this was developed against. In EDT
    /// (UTC-4) `ps -o lstart=` printed "Wed Sep 23 05:16:28 2026" for the same process.
    @Test("parses a real procStart string as UTC")
    func parsesAsUTC() {
        #expect(ProcStartParser.parse("Wed Sep 23 09:16:28 2026") == utc(2026, 9, 23, 9, 16, 28))
    }

    /// `ctime` pads single-digit days with a second space. Real sample from disk.
    @Test("handles ctime's double-space padding for single-digit days")
    func handlesDoubleSpacePadding() {
        #expect(ProcStartParser.parse("Sun Sep  6 03:57:25 2026") == utc(2026, 9, 6, 3, 57, 25))
    }

    @Test("rejects garbage rather than guessing")
    func rejectsGarbage() {
        #expect(ProcStartParser.parse("") == nil)
        #expect(ProcStartParser.parse("yesterday") == nil)
        #expect(ProcStartParser.parse("Wed Sep 23 2026") == nil)
    }

    /// The regression this whole type exists for.
    ///
    /// `procStart` is UTC; `ps -o lstart=` is local. Treating the recorded string as
    /// local time shifts it by the UTC offset, and the liveness check then rejects
    /// every live session — everywhere except UTC.
    @Test("a UTC procStart matches the kernel start time it denotes")
    func matchesKernelStartTime() {
        #expect(ProcStartParser.matches("Wed Sep 23 09:16:28 2026",
                                        actualStart: utc(2026, 9, 23, 9, 16, 28)))
    }

    @Test("parsing as local time would have broken liveness in EDT")
    func localTimeInterpretationWouldFail() {
        let kernelStart = utc(2026, 9, 23, 9, 16, 28)
        // What a local-time parser produces on an EDT machine: the same wall-clock
        // reading, four hours later in absolute terms.
        let misparsed = kernelStart.addingTimeInterval(4 * 3600)
        #expect(abs(misparsed.timeIntervalSince(kernelStart)) > 2,
                "the bug must exceed tolerance, otherwise this test proves nothing")
        #expect(ProcStartParser.matches("Wed Sep 23 09:16:28 2026", actualStart: misparsed) == false)
    }

    /// `procStart` has one-second resolution, so sub-second drift is expected.
    @Test("tolerates sub-second drift")
    func toleratesSubSecondDrift() {
        let kernelStart = utc(2026, 9, 23, 9, 16, 28).addingTimeInterval(0.812)
        #expect(ProcStartParser.matches("Wed Sep 23 09:16:28 2026", actualStart: kernelStart))
    }

    /// The POSIX locale is pinned inside the parser; without it this fails on a device
    /// set to, say, zh_CN, where month and weekday names are localised.
    @Test("month and weekday names do not depend on the user's locale")
    func isLocaleIndependent() {
        #expect(ProcStartParser.parse("Tue Aug 11 16:49:52 2026") == utc(2026, 8, 11, 16, 49, 52))
    }
}
