actor OwnedBarrier {
    enum Permit: Sendable { case permitted, alreadyReleased, missing }
    private struct Entry {
        let control: OperationControl
        var firstReleased = false
        var secondReleased = false
    }
    private let limit: Int
    private var entries: [UInt64: Entry] = [:]

    init(limit: Int) { self.limit = limit }

    func register(ticket: UInt64, control: OperationControl) -> RegistrationDisposition {
        if control.isCancelled { return .cancelledBeforeRegistration }
        guard entries[ticket] == nil, entries.count < limit else { return .rejected }
        entries[ticket] = Entry(control: control)
        return .registered
    }

    // A release permit does not resume a task. The ledger journals the permit
    // before synchronously resolving its cell, making the acknowledgement causal.
    func prepareRelease(ticket: UInt64, gate: Gate) -> Permit {
        guard var entry = entries[ticket] else { return .missing }
        switch gate {
        case .suspension:
            guard !entry.firstReleased else { return .alreadyReleased }
            entry.firstReleased = true
        case .commit:
            guard !entry.secondReleased else { return .alreadyReleased }
            entry.secondReleased = true
        }
        entries[ticket] = entry
        return .permitted
    }

    func remove(ticket: UInt64) -> Bool { entries.removeValue(forKey: ticket) != nil }
    func count() -> Int { entries.count }
}
