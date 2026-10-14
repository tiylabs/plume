import Foundation
import PlumeKit

/// The pure parts of the agent API: change planning, line endings, refs, caches, limits, decoding.
func runAgentDomainTests() {

    Check.suite("Agent · change planner") {

        Check.test("a unique replace swaps exactly that passage") {
            let out = try! NoteChangePlanner.apply([.replace("采用 HTTP 服务。", with: "采用本地 stdio MCP。")], to: "# 方案\n\n采用 HTTP 服务。\n\n其他保留。\n")
            Check.equal(out, "# 方案\n\n采用本地 stdio MCP。\n\n其他保留。\n")
        }

        Check.test("every replace matches the original, not the previous change's output") {
            let out = try! NoteChangePlanner.apply([.replace("A", with: "B"), .replace("B", with: "C")], to: "A then B\n")
            Check.equal(out, "B then C\n")
        }

        Check.test("missing, repeated and overlapping matches fail the whole request") {
            let base = "one two one\n"
            func code(_ changes: [NoteChange]) -> AgentErrorCode? {
                do { _ = try NoteChangePlanner.apply(changes, to: base); return nil } catch { return (error as? AgentFailure)?.code }
            }
            Check.equal(code([.replace("three", with: "x")]), .matchNotFound)
            Check.equal(code([.replace("one", with: "x")]), .matchAmbiguous)
            Check.equal(code([.replace("one two", with: "x"), .replace("two one", with: "y")]), .changesOverlap)
            Check.equal(code([.replace("ONE two", with: "x")]), .matchNotFound, "matching is case-sensitive")
            Check.equal(code([.replace("two", with: "2"), .replace("nope", with: "x")]), .matchNotFound, "nothing applied when one change fails")
        }

        Check.test("overlapping occurrences of the same text are ambiguous") {
            Check.expect((try? NoteChangePlanner.apply([.replace("aa", with: "b")], to: "aaa\n")) == nil)
        }

        Check.test("append adds at the end, at most once, with the agent's own spacing") {
            let out = try! NoteChangePlanner.apply([.append("\n## 待办\n\n- [ ] x\n")], to: "# T\n\nbody\n")
            Check.equal(out, "# T\n\nbody\n\n## 待办\n\n- [ ] x\n")
            Check.expect((try? NoteChangePlanner.apply([.append("a"), .append("b")], to: "x\n")) == nil)
        }

        Check.test("an insert is a replace of a unique anchor with anchor plus text") {
            let out = try! NoteChangePlanner.apply([.replace("## B\n", with: "## A2\n\nnew\n\n## B\n")], to: "## A\n\n## B\n")
            Check.equal(out, "## A\n\n## A2\n\nnew\n\n## B\n")
        }

        Check.test("a result that is blank is refused") {
            do {
                _ = try NoteChangePlanner.apply([.replace("# T\n", with: "")], to: "# T\n")
                Check.expect(false, "expected EMPTY_CONTENT")
            } catch let f as AgentFailure {
                Check.equal(f.code, .emptyContent)
            } catch {}
        }

        Check.test("malformed changes are invalid requests") {
            for changes in [[], [NoteChange(kind: .replace, oldText: "", newText: "x")], [NoteChange(kind: .replace, oldText: "a")],
                            [NoteChange(kind: .append, text: "")], [NoteChange(kind: .append, oldText: "a", text: "b")],
                            Array(repeating: NoteChange.replace("a", with: "b"), count: AgentLimits.maxChangesPerRequest + 1)] {
                do { _ = try NoteChangePlanner.apply(changes, to: "a\n"); Check.expect(false) } catch let f as AgentFailure {
                    Check.equal(f.code, .invalidRequest)
                } catch {}
            }
        }

        Check.test("a match never splits a grapheme: no half of é, no half of an emoji") {
            let decomposed = "caf\u{65}\u{301} e\n"   // "café" with a combining accent, then " e"
            let out = try! NoteChangePlanner.apply([.replace("e", with: "E")], to: decomposed)
            Check.equal(out, "caf\u{65}\u{301} E\n", "only the standalone e is a match")
            let family = "👨‍👩‍👧 and 👨\n"
            let out2 = try! NoteChangePlanner.apply([.replace("👨", with: "X")], to: family)
            Check.equal(out2, "👨‍👩‍👧 and X\n")
        }

        // The final line ending is the one exception: loading already normalises a note to exactly one
        // trailing "\n" (MarkdownDocument.normalizeTrailingNewline), and a modify starts from that.
        Check.test("CRLF: matched as LF, untouched lines keep CRLF, the new passage is as sent") {
            let base = "# T\r\n\r\nold line\r\nkeep\r\n"
            let out = try! NoteChangePlanner.apply([.replace("old line", with: "new line")], to: base)
            Check.equal(out, "# T\r\n\r\nnew line\r\nkeep\n")
            let spanning = try! NoteChangePlanner.apply([.replace("old line\nkeep", with: "a\nb")], to: base)
            Check.equal(spanning, "# T\r\n\r\na\nb\n")
            let crInOld = try! NoteChangePlanner.apply([.replace("old line\r\nkeep", with: "z")], to: base)
            Check.equal(crInOld, "# T\r\n\r\nz\n", "an old_text sent with CRLF still matches")
        }

        Check.test("the result has exactly one trailing newline") {
            Check.equal(try! NoteChangePlanner.apply([.append("tail\n\n\n")], to: "x\n"), "x\ntail\n")
        }
    }

    Check.suite("Agent · line endings") {
        Check.test("CRLF and lone CR become LF, with a map back") {
            let map = LineEndingMap(raw: "a\r\nb\rc\n")
            Check.equal(map.lfText, "a\nb\nc\n")
            Check.equal(map.rawRange(0..<1), 0..<1)
            Check.equal(map.rawRange(0..<2), 0..<3, "the LF that came from CRLF covers both scalars")
            Check.expect(map.hasCarriageReturns)
            Check.expect(!LineEndingMap(raw: "plain\n").hasCarriageReturns)
        }
    }

    Check.suite("Agent · note refs and path policy") {
        Check.test("a ref round-trips and binds profile and vault") {
            let ref = NoteRef(profile: "dev", vaultID: "v1", filename: "2026-10-14-1200-a.md").encoded
            Check.expect(ref.hasPrefix("note:"))
            Check.equal(try? NoteRef.decode(ref, profile: "dev", vaultID: "v1").filename, "2026-10-14-1200-a.md")
            func code(_ raw: String, _ profile: String = "dev", _ vault: String = "v1") -> AgentErrorCode? {
                do { _ = try NoteRef.decode(raw, profile: profile, vaultID: vault); return nil } catch { return (error as? AgentFailure)?.code }
            }
            Check.equal(code(ref, "release"), .invalidNoteRef)
            Check.equal(code(ref, "dev", "v2"), .vaultChanged)
            Check.equal(code("note:garbage"), .invalidNoteRef)
            Check.equal(code("/etc/passwd"), .invalidNoteRef)
        }

        Check.test("forged refs cannot name anything but a visible .md in the vault") {
            for bad in ["../x.md", "a/b.md", ".hidden.md", "x.txt", "", "a\u{0}.md", "line\nbreak.md", String(repeating: "长", count: 90) + ".md"] {
                let forged = NoteRef(profile: "dev", vaultID: "v", filename: bad).encoded
                Check.expect((try? NoteRef.decode(forged, profile: "dev", vaultID: "v")) == nil, "accepted \(bad)")
            }
            Check.expect((try? NotePathPolicy.validate("a..b.md")) != nil, "dots without a separator are an ordinary name")
        }

        Check.test("vault identity follows the resolved path") {
            let a = URL(fileURLWithPath: "/tmp/vault-a")
            Check.equal(VaultIdentity.of(a), VaultIdentity.of(URL(fileURLWithPath: "/tmp/vault-a/")))
            Check.notEqual(VaultIdentity.of(a), VaultIdentity.of(URL(fileURLWithPath: "/tmp/vault-b")))
        }

        Check.test("request IDs must be UUIDs and are compared case-insensitively") {
            let id = UUID().uuidString
            Check.equal(try? AgentRequestID.validate(id), id.lowercased())
            Check.expect((try? AgentRequestID.validate("1")) == nil)
        }
    }

    Check.suite("Agent · caches and limits") {
        Check.test("tokens expire, are evicted oldest first, and are random") {
            final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
            let clock = Clock()
            let cache = ExpiringTokenCache<Int>(prefix: "version:", lifetime: 600, capacity: 2, now: { clock.now })
            let a = cache.insert(1).token
            let b = cache.insert(2).token
            Check.notEqual(a, b)
            if case .found(1) = cache.lookup(a) {} else { Check.expect(false, "a should be found") }
            _ = cache.insert(3)
            if case .expired = cache.lookup(a) {} else { Check.expect(false, "a should be evicted") }
            clock.now = clock.now.addingTimeInterval(601)
            if case .expired = cache.lookup(b) {} else { Check.expect(false, "b should have expired") }
            if case .unknown = cache.lookup("nonsense") {} else { Check.expect(false, "foreign token is unknown") }
        }

        Check.test("the rate limiter refuses with retry_after and frees up after the window") {
            final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }
            let clock = Clock()
            let limiter = AgentRateLimiter(limit: 2, window: 60, now: { clock.now })
            try! limiter.take()
            try! limiter.take()
            do {
                try limiter.take()
                Check.expect(false, "third write should be refused")
            } catch let f as AgentFailure {
                Check.equal(f.code, .rateLimited)
                Check.equal(f.details?["retry_after"], "60")
                Check.expect(f.retryable)
            } catch {}
            clock.now = clock.now.addingTimeInterval(60)
            Check.expect((try? limiter.take()) != nil)
        }

        Check.test("published limits are the plan's numbers") {
            Check.equal(AgentLimits.listDefaultPage, 20)
            Check.equal(AgentLimits.listMaxPage, 100)
            Check.equal(AgentLimits.noteMaxBytes, 1_048_576)
            Check.equal(AgentLimits.maxChangesPerRequest, 32)
            Check.equal(AgentLimits.ipcMaxFrameBytes, 4 * 1_048_576)
            Check.equal(AgentLimits.maxExamples, 3)
            Check.equal(AgentLimits.examplesMaxBytes, 32 * 1024)
            Check.equal(AgentLimits.writesPerMinute, 30)
            Check.equal(AgentLimits.versionLifetime, 600)
        }
    }

    Check.suite("Agent · decoding and wire names") {
        Check.test("requests decode strictly with a path in the message") {
            let bad: JSONValue = .object(["note_ref": .string("x"), "expected_version": .string("v"), "changes": .array([.object(["kind": .string("rewrite")])]), "request_id": .string(uuid())])
            do {
                _ = try bad.decode(ModifyNoteRequest.self)
                Check.expect(false)
            } catch let f as AgentFailure {
                Check.equal(f.code, .invalidRequest)
                Check.expect(f.message.contains("changes[0]"), f.message)
            } catch {}
            Check.expect((try? JSONValue.object(["query": .number(3)]).decode(SearchNotesRequest.self)) == nil, "a number is not a query")
        }

        Check.test("wire names are snake_case and errors carry stable codes") {
            let failure = AgentFailure(.noteBusy, "busy", details: ["reason": "editing"], requestID: "r", operationState: .rejected)
            let text = String(decoding: try! AgentJSON.encoder.encode(failure), as: UTF8.self)
            Check.expect(text.contains("\"code\":\"NOTE_BUSY\""), text)
            Check.expect(text.contains("\"request_id\":\"r\""), text)
            Check.expect(text.contains("\"operation_state\":\"rejected\""), text)
            Check.expect(text.contains("\"retryable\":true"), text)
            let all = Set(AgentErrorCode.allCases.map(\.rawValue))
            for code in ["ACCESS_DISABLED", "AUTH_FAILED", "PERMISSION_DENIED", "APP_NOT_READY", "APP_INSTANCE_MISMATCH",
                         "PROTOCOL_MISMATCH", "REQUEST_TIMEOUT", "CONNECTION_BLOCKED", "VAULT_UNAVAILABLE", "VAULT_CHANGED",
                         "NOTE_NOT_FOUND", "INVALID_NOTE_REF", "NOTE_NOT_AVAILABLE", "DOWNLOAD_TIMEOUT", "CONTENT_TOO_LARGE",
                         "VERSION_CONFLICT", "VERSION_EXPIRED", "MATCH_NOT_FOUND", "MATCH_AMBIGUOUS", "CHANGES_OVERLAP",
                         "INVALID_REQUEST", "EMPTY_CONTENT", "CURSOR_EXPIRED", "NOTE_BUSY", "SAVE_FAILED", "OUTCOME_UNKNOWN",
                         "REQUEST_ID_REUSED", "OPERATION_EXPIRED", "RATE_LIMITED"] {
                Check.expect(all.contains(code), "missing \(code)")
            }
        }

        Check.test("tool names and permission tiers") {
            Check.equal(AgentTool.allCases.map(\.rawValue), ["get_writing_context", "list_notes", "search_notes", "read_note", "create_note", "modify_note", "get_operation"])
            Check.expect(AgentPermission.readOnly.allows(.readNote))
            Check.expect(!AgentPermission.readOnly.allows(.createNote))
            Check.expect(!AgentPermission.off.allows(.listNotes))
            Check.expect(AgentPermission.readWrite.allows(.modifyNote))
        }
    }

    Check.suite("Agent · format warnings") {
        Check.test("front matter, blocks in list items and conflict markers are flagged; plain notes are not") {
            Check.equal(FormatWarnings.check("# Title\n\n- item\n- [ ] task\n  - nested\n").map(\.code), [])
            Check.equal(FormatWarnings.check("---\ntitle: x\n---\n").map(\.code), ["front_matter"])
            Check.equal(FormatWarnings.check("# T\n\n- - item\n").map(\.code), ["block_in_list_item"])
            Check.equal(FormatWarnings.check("# T\n\n1. # heading\n").map(\.code), ["block_in_list_item"])
            Check.equal(FormatWarnings.check("# T\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n").map(\.code), ["git_conflict_markers"])
            Check.equal(FormatWarnings.check("# T\n```\n- - not a list in code\n```\n").map(\.code), [])
        }
    }
}
