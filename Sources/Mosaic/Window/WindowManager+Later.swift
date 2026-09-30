import AppKit

/// Every deferred step of the window manager goes through `later`, so the two guards each one
/// used to hand-roll — and that one of them forgot — are structural rather than remembered:
///
///   • it captures `sleepGeneration` and is a no-op if the machine slept since it was scheduled
///     (a step scheduled before a sleep must never land after it and resume a machine that went
///     back under) — unless `acrossSleep`, for work that must survive one: the display settle,
///     which releases its own suspend reason; the debounced save; the end-of-boot cleanup;
///   • it is a no-op while `suspended` — unless `whileSuspended`, for the steps that ARE the
///     wake/dock sequence and lift the suspension themselves.
///
/// A named step replaces any pending step of the same name (the debounce pattern: a repeated
/// event coalesces instead of piling up) and can be cancelled by name. Anonymous steps run once.
/// `body` receives the manager rather than capturing it, so a retained work item can't hold a
/// cycle back through the pending table.
extension WindowManager {
    @discardableResult
    func later(_ name: String? = nil, in delay: TimeInterval,
               whileSuspended: Bool = false, acrossSleep: Bool = false,
               _ body: @escaping (WindowManager) -> Void) -> DispatchWorkItem {
        if let name { deferredByName[name]?.cancel() }
        let generation = sleepGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let name, self.deferredByName[name] != nil { self.deferredByName[name] = nil }
            if !acrossSleep, self.sleepGeneration != generation { return }
            if !whileSuspended, self.suspended { return }
            body(self)
        }
        if let name { deferredByName[name] = work }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    func cancelLater(_ name: String) {
        deferredByName[name]?.cancel()
        deferredByName[name] = nil
    }
}
