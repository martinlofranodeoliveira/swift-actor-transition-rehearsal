# Design — development 0.1.0

## Real execution, not scheduling simulation

`Rehearsal` is a real Swift actor. It owns generation, capacity accounting, records, terminal receipts and a logical journal. `OwnedBarrier` is a separate actor with a private bounded table. Actual Swift `Task` values invoke `execute` and suspend on checked continuations. No custom executor or synthetic scheduler determines actor execution order.

The immutable token carries admission generation, actor-assigned ticket and a private control identity. The identity prevents accidentally accepting a similarly numbered token from another ledger. Task creation does not assign journal order. Each journal append occurs inside the ledger actor, with checked UInt64 addition. Generation changes also use checked addition.

## Memory model and reentrancy

Actor isolation serializes isolated access, not a whole async invocation. During `await`, other actor calls can mutate generation or acknowledge cancellation. On every execution await return, `checkpoint` verifies that the record remains active, owns a reservation, has not requested cancellation, and still has the admitted generation. Checks also occur after removal and immediately before the synchronous terminal decision. A generation mismatch never becomes valid again because generation only increases.

Snapshots contain only Sendable value types: immutable structs/enums, strings and value arrays. They contain no record, mutex, continuation, actor or control reference. Swift collection copy-on-write storage is not mutable actor-owned reference exposure. Canonical encoding of an old snapshot does not consult the actor.

`OperationControl` and `OneShot` are Sendable classes with immutable fields and private `Synchronization.Mutex` state. There is no `@unchecked Sendable`. The mutex establishes ordering between cancellation and the terminal decision, including cancellation delivered concurrently on a different executor. A request that precedes the terminal checkpoint prevents commit; one after a committed checkpoint is too late. Actor code performs no await between that decision and receipt/state publication. This is a local in-memory linearization point, not a transaction/durability claim.

## Continuation ownership

A cell has one allowed installation and one allowed completion. `finish` stores its value and takes the continuation under the mutex, then resumes outside the lock. `wait` either stores a continuation or observes the retained result. Thus cancellation before installation cannot be lost; completion after installation takes and resumes exactly one continuation. Repeated finish returns false. Repeated wait throws `observerAlreadyUsed`.

The barrier actor inserts a control cell into its table before returning a registration disposition. The ledger assigns a registration event, then invokes the cell wait. Only the synchronous **post-installation** callback resolves the public registration acknowledgement. A registered acknowledgement means the table insertion and the installation path both occurred; it does not promise the task is still parked when the consumer observes it. Cancellation may already have resolved it. Pre-cancelled registration explicitly reports `cancelledBeforeRegistration` and inserts no table entry.

The second cell repeats this installation protocol for resumption acknowledgement. The same barrier entry owns both gates, so an operation never needs two waiter-table slots. Waiter reservations include admitted but not-yet-registered operations. The barrier is private: admission reservations cannot be stolen by unrelated callers.

Release has two steps. The barrier grants a single release permit without waking the task. After returning to the ledger, release rechecks the record/phase, appends the release event, then synchronously resolves the appropriate cell. No terminal event can causally precede this release journal event. Cleanup removes the table entry and returns an actual removal acknowledgement before terminal accounting releases reservations.

## Reservation policy

Admission validates all bounds before mutation: capacity, live task allowance, waiter slot, retained record, future terminal receipt and ten journal positions. Ten covers the longest path:

1. admitted;
2. executing;
3. registered;
4. released/suspension;
5. resumed;
6. released/commit;
7. cleaning;
8. removed;
9. terminal;
10. cancellationAcknowledged, either early or late.

The actor cannot spend reserved positions on generation changes. Terminal completion releases unused positions except one for an unrequested application cancellation. Records and receipts are never evicted. Their maximum retained count bounds total lifetime admissions. Smaller event bounds can prevent any admission. Cancellation, cleanup and terminal acknowledgement do not need a fresh resource allocation budget from admission policy. Ordinary allocator failure/process death is outside this contract.

## Scenario ownership

Each scenario retains a bounded `RunOwner` task array and joins every task. On error it requests cancellation on all retained tasks and joins them before propagating failure. There is no fire-and-forget forwarding task in cancellation handlers. Scenarios coordinate with registration, resumption, release and task-result acknowledgements, never sleeps. A non-cooperating continuation bug can still block Swift cleanup; external CI/container timeouts classify that run as incomplete.

The MainActor only owns scenario task handles and protocol sequencing. It does not replace the ledger actor, barrier actor or Swift task runtime. Tests also race two actual completion tasks and deliberately make no assertion about which wins.

## Offline build process ownership

The Python build gate is separate from the runtime library/CLI. It launches only fixed Swift compiler commands and the installed owned CLI. A direct child establishes a fresh session, acknowledges through a private pipe and execs the tool. The parent retains the unreaped child identity, bounds combined output and elapsed observation, and is the sole reaper. Any numeric signal occurs before reaping. It does not discover descendants by PID, scan process trees or reuse a PID as identity evidence.

Compiler and CLI behavior must not escape the owned session. Timeout/output exhaustion triggers one bounded cleanup attempt; unreaped children or retained pipes are explicit incomplete-cleanup failures. This mechanism cannot prove universal termination or sandbox arbitrary programs. Docker invocation, image acquisition and final namespace teardown belong to the external trusted harness.

## References for semantics

- [SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
- [Swift concurrency guide](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Swift 6 data-race safety](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/dataracesafety/)

These explain semantics; they are not implementation code or evidence of this package's test results.
