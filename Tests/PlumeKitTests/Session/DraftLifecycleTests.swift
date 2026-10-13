import Foundation
import PlumeKit

/// The draft's create answering after the panel moved on. Each scenario is the sequence the panel
/// runs, with the vault's answer delivered where the real one arrives — later.
func runDraftLifecycleTests() {
    Check.suite("Draft lifecycle") {

        Check.test("a fresh lifecycle has no draft, and begin makes one") {
            var draft = DraftLifecycle()
            Check.equal(draft.isDraft, false)
            draft.begin()
            Check.equal(draft.isDraft, true)
        }

        Check.test("the draft that asked for the create adopts its answer") {
            var draft = DraftLifecycle()
            draft.begin()
            let ticket = draft.ticket
            Check.equal(draft.isCurrent(ticket), true)
            draft.end()
            Check.equal(draft.isDraft, false, "adopting the file ends the draft")
        }

        Check.test("an answer after a real note opened is not adopted") {
            var draft = DraftLifecycle()
            draft.begin()
            let ticket = draft.ticket
            draft.end()                                   // `open` ends any draft
            Check.equal(draft.isCurrent(ticket), false)
        }

        Check.test("an answer meant for the previous draft is not adopted by the next one") {
            // The data-loss sequence: type in A, ⌘N inside the debounce, A's create answers while B
            // is showing. A bare isDraft flag is true again here and bound B's buffer to A's file.
            var draft = DraftLifecycle()
            draft.begin()                                 // draft A
            let ticketA = draft.ticket                    // A's create is enqueued
            draft.begin()                                 // ⌘N: draft B replaces A
            Check.equal(draft.isDraft, true, "B is a draft, which is exactly why a flag is not enough")
            Check.equal(draft.isCurrent(ticketA), false, "A's answer must not be adopted by B")
            Check.equal(draft.isCurrent(draft.ticket), true, "B's own answer still would be")
        }

        Check.test("tickets stay distinct across many drafts, and an ended draft never matches") {
            var draft = DraftLifecycle()
            var seen = Set<DraftLifecycle.Ticket>()
            for _ in 0..<50 {
                draft.begin()
                Check.expect(seen.insert(draft.ticket).inserted, "a ticket was reused")
            }
            let last = draft.ticket
            draft.end()
            Check.equal(draft.isCurrent(last), false)
            draft.begin()
            Check.equal(draft.isCurrent(last), false, "a later draft is not an earlier ticket's draft")
        }
    }
}
