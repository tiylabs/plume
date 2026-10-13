import Foundation
import PlumeKit

func runNavigationHistoryTests() {
    Check.suite("NavigationHistory") {

        Check.test("Back and Forward walk the visits in order, and stop at the ends") {
            var h = NavigationHistory()
            ["a", "b", "c"].forEach { h.recordVisit($0) }
            Check.equal(h.back(), "b")
            Check.equal(h.back(), "a")
            Check.equal(h.back(), nil, "nothing before the first visit")
            Check.equal(h.forward(), "b")
            Check.equal(h.forward(), "c")
            Check.equal(h.forward(), nil, "nothing after the last")
        }

        Check.test("an empty history goes nowhere") {
            var h = NavigationHistory()
            Check.equal(h.back(), nil)
            Check.equal(h.forward(), nil)
            h.recordVisit("a")
            Check.equal(h.back(), nil, "one entry has no before")
        }

        Check.test("visiting the note already on screen adds nothing") {
            var h = NavigationHistory()
            h.recordVisit("a"); h.recordVisit("a")
            Check.equal(h.entries, ["a"])
        }

        Check.test("a new visit from the middle discards what was ahead, as a browser does") {
            var h = NavigationHistory()
            ["a", "b", "c"].forEach { h.recordVisit($0) }
            _ = h.back(); _ = h.back()                // on a
            h.recordVisit("d")
            Check.equal(h.entries, ["a", "d"])
            Check.equal(h.forward(), nil, "c is no longer ahead")
            Check.equal(h.back(), "a")
        }

        Check.test("walking the history does not itself add to it") {
            var h = NavigationHistory()
            ["a", "b"].forEach { h.recordVisit($0) }
            _ = h.back(); _ = h.forward(); _ = h.back()
            Check.equal(h.entries, ["a", "b"], "Back would otherwise alternate between two notes forever")
        }

        Check.test("it keeps only the most recent fifty, and still points at the newest") {
            var h = NavigationHistory()
            for n in 0..<(NavigationHistory.limit + 10) { h.recordVisit("n\(n)") }
            Check.equal(h.entries.count, NavigationHistory.limit)
            Check.equal(h.entries.first, "n10")
            Check.equal(h.entries.last, "n\(NavigationHistory.limit + 9)")
            Check.equal(h.back(), "n\(NavigationHistory.limit + 8)")
        }

        Check.test("renaming rewrites every entry for the old name, so Back never lands on a dead file") {
            var h = NavigationHistory()
            ["a", "b", "a"].forEach { h.recordVisit($0) }
            h.rename("a", to: "z")
            Check.equal(h.entries, ["z", "b", "z"])
            Check.equal(h.back(), "b")
            Check.equal(h.back(), "z")
        }
    }
}
