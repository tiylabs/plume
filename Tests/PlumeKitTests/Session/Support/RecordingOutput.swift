import Foundation
import PlumeKit

/// Records everything a session does to the outside world, in order.
@MainActor
final class RecordingOutput: NoteSessionOutput {

    enum Event: Equatable {
        case load(LoadedNote)
        case renamed(String)
        case pinned(Bool)
        case banner(Banner?)
        case toast(String)
        case news(String)
        case focus
        case pinsChanged
        case switcherRefresh
        case vaultGone
    }

    private(set) var events: [Event] = []
    var isPanelVisible = true
    /// What `vaultIsGone` is told. The session decides *whether* to call it from the settings' folder.

    func clear() { events = [] }

    func load(_ note: LoadedNote) { events.append(.load(note)) }
    func currentNoteRenamed(to filename: String) { events.append(.renamed(filename)) }
    func pinnedChanged(_ pinned: Bool) { events.append(.pinned(pinned)) }
    func show(_ banner: Banner?) { events.append(.banner(banner)) }
    func toast(_ text: String) { events.append(.toast(text)) }
    func news(_ text: String) { events.append(.news(text)) }
    func focusEditor() { events.append(.focus) }
    func pinsChanged() { events.append(.pinsChanged) }
    func switcherNeedsRefresh() { events.append(.switcherRefresh) }
    func vaultIsGone() { events.append(.vaultGone) }

    // MARK: Queries

    var loads: [LoadedNote] { events.compactMap { if case .load(let n) = $0 { n } else { nil } } }
    var banners: [Banner?] { events.compactMap { if case .banner(let b) = $0 { .some(b) } else { nil } } }
    var renames: [String] { events.compactMap { if case .renamed(let n) = $0 { n } else { nil } } }
    var toasts: [String] { events.compactMap { if case .toast(let t) = $0 { t } else { nil } } }
    var newsItems: [String] { events.compactMap { if case .news(let t) = $0 { t } else { nil } } }
    func count(_ event: Event) -> Int { events.filter { $0 == event }.count }
}
