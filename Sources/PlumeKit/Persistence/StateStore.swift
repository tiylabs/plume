import Foundation

/// Holds `AppState` in memory and writes it to disk without doing so on every keystroke.
///
/// Caret offsets change constantly (decision 11 restores them exactly, so they are recorded on every
/// selection change) and `state.json` is pretty-printed for a human to read. Writing it synchronously
/// per keystroke would be the one piece of I/O on the hot path. Instead it coalesces, and flushes for
/// real at the three moments that matter — dismiss, blur and quit — which are the same three moments
/// the note itself is flushed (decision 10).
@MainActor
public final class StateStore {

    private let store: JSONFileStore<AppState>
    private let scheduler: any Scheduling
    private var pending: (any Cancellable)?

    /// Long enough to swallow a burst of caret moves, short enough that a crash costs at most a
    /// couple of seconds of "where the caret was" — which is recoverable knowledge, unlike the note.
    public static let coalesceInterval: TimeInterval = 2.0

    public private(set) var value: AppState

    public let loadOutcome: JSONFileStore<AppState>.Outcome

    /// The app's own `state.json`, in the Application Support folder of the running build.
    public convenience init() {
        let store = (try? JSONFileStore<AppState>.inApplicationSupport("state.json"))
            ?? JSONFileStore<AppState>(
                url: BuildProfile.current.fallbackSupportDirectory().appendingPathComponent("state.json")
            )
        self.init(store: store, scheduler: MainQueueScheduler())
    }

    /// A store over any file, with any clock: what the suite uses, with a temporary folder and a
    /// scheduler it advances by hand.
    public init(store: JSONFileStore<AppState>, scheduler: any Scheduling) {
        self.store = store
        self.scheduler = scheduler
        (value, loadOutcome) = store.load(default: AppState())
    }

    /// Mutates the state and schedules a save.
    public func update(_ body: (inout AppState) -> Void) {
        body(&value)
        scheduleSave()
    }

    private func scheduleSave() {
        pending?.cancel()
        pending = scheduler.schedule(after: Self.coalesceInterval) { [weak self] in self?.save() }
    }

    public func save() {
        pending?.cancel()
        pending = nil
        do {
            try store.save(value)
        } catch {
            NSLog("Plume: could not save state — %@", String(describing: error))
        }
    }
}
