# AdaptiveTransfer

**Your upload pipeline contains a number someone guessed. It is a guess about
capacity that belongs to a server you do not own, compiled into a client you
ship to millions of devices — and when it is wrong in the expensive direction,
nothing in your telemetry says so.**

```swift
uploadQueue.maxConcurrentOperationCount = 8   // ← this line
```

This package replaces that line with a control loop that discovers the
concurrency limit from the latency it observes, the way congestion control has
worked since Jacobson. It is a Swift 6 package with no dependencies, a pure
policy core with no I/O in it at all, and a deterministic queueing simulation
that regenerates every number below on each push.

---

## Why this matters

Too low a limit leaves throughput on the table, somebody notices, and the number
goes up. That failure is self-correcting.

Too high a limit does not reduce throughput. The excess work moves into a queue
you do not own and cannot instrument. By Little's Law the residence time of that
queue grows with its depth while the completion rate stays flat, so your
throughput dashboard is healthy, your error rate is zero, and the user is
watching a spinner. There is nothing to alert on, because nothing is failing.

Then it gets worse. Past the point where the server starts shedding load, the
extra concurrency stops producing queueing and starts producing *rejections* —
and every rejection becomes a retry, and every retry becomes more offered load.
The client is no longer a slow upload; it is a retry storm wearing an upload's
clothes. The simulation below reaches that state, and the numbers are not subtle.

The asymmetry is the whole argument. **A team cannot pick a safe number, because
the safe side of the number is not where the throughput is, and the unsafe side
is a cliff rather than a slope.** So the client has to measure instead of guess.

---

## The measurement

`CapacityExperiment` is a deterministic discrete-event simulation in virtual
time. One scenario, five strategies, byte-identical conditions:

> 300 chunks. A server with usable capacity 8 and a 40 ms service time, which
> drops to capacity **2** two hundred milliseconds in — a noisy neighbour, a
> handoff onto a congested cell, a backend that started shedding. The client is
> told nothing. Past 4× capacity in flight the server sheds.

Latency is measured **per chunk, end to end** — from a chunk's first admission
to its eventual success, including attempts the server threw away. That choice
is load-bearing: counting only completed *requests* makes shedding look like a
latency improvement, because the shed attempts leave the sample and the
survivors were fast.

| strategy | completed | requests shed | finished | p50 | p95 | p99 |
|---|---|---|---|---|---|---|
| fixed limit 4 | 300 / 300 | 0 | 5,800 ms | 80 ms | 80 ms | 80 ms |
| fixed limit 8 | 300 / 300 | 0 | 5,400 ms | 160 ms | 160 ms | 160 ms |
| fixed limit 16 | **55 / 300** | **29,985** | *hit the 600 s horizon* | — | — | — |
| fixed limit 32 | **71 / 300** | **29,977** | *hit the 600 s horizon* | — | — | — |
| **`GradientLimiter`** | 300 / 300 | 12 | 5,775 ms | 80 ms | 100 ms | 705 ms |

Read across the fixed rows. Going from 8 to 16 — one doubling, the kind of
change that ships in a "speed up uploads" PR with a green build — turns a
transfer that finishes in 5.4 seconds into one that delivers 55 of 300 chunks in
ten minutes and burns thirty thousand requests doing it. Nothing in the client
distinguishes 8 from 16; the server's capacity does, and the server never told
anybody.

The controller's row is the point: it completed the transfer in **5,775 ms
without having been told anything**, and converged to a limit of 4 against an
actual capacity of 2.

### What it costs, stated plainly

The controller is not free and the table says so.

* **A fixed limit of 8 finishes 6.9% sooner** (5,400 ms vs 5,775 ms). Overload
  that stays under the shedding threshold really does buy a little throughput.
* **A fixed limit of 4 — the best possible guess for this scenario — beats the
  controller on the tail** (p95 80 ms vs 100 ms) and sheds nothing. It could only
  have been chosen by someone who already knew the capacity schedule.
* **The controller's p99 is 705 ms**, against 160 ms for fixed 8. That tail is
  entirely its startup overshoot: it probed to 22 in flight while capacity was
  still 8, the capacity collapsed underneath it, and 12 requests were shed before
  it converged. Twelve of three hundred, but they are in the p99 and pretending
  otherwise would be dishonest.

So the claim is not "adaptive is faster". The claim is narrower and harder to
argue with: **the controller does not have to be right in advance, and its worst
case is a 705 ms tail on 4% of chunks, while a wrong guess's worst case is a
transfer that never finishes.** `testAPerfectlyTunedFixedGuessStillBeatsTheController`
asserts the counter-evidence, on purpose — a suite that only held results
flattering the thing it tests would not be worth reading.

Regenerate the whole table:

```bash
swift test --filter CapacityExperimentTests/testPublishNumbersForTheReadme
```

---

## The control law

```
gradient = clamp(noLoadRTT / observedRTT, 0.5, 1.0)
headroom = queueFactor * sqrt(limit)
target   = limit * gradient + headroom
limit   += smoothing * (target - limit)
```

Latency is the signal because it moves *before* anything fails. A gradient of
1.0 means no queueing was detected, and `headroom` is what lets the limit climb
— additively, proportional to `sqrt(limit)`, so probing gets more cautious as the
limit gets larger. A gradient below 1.0 multiplies the limit down. Additive
increase, multiplicative decrease: over-estimating capacity is much more
expensive than under-estimating it, so the responses are deliberately asymmetric.
The shape follows TCP Vegas and Netflix's `concurrency-limits` rather than
inventing a control law with no production evidence behind it.

A dropped request is handled separately: a multiplicative cut, and its
round-trip time is **never** folded into the no-load estimate. A 30-second
timeout says nothing about the network's floor, and folding it in would raise
that floor and make the controller *less* sensitive exactly when it needs to be
more. `testDroppedSampleDoesNotPoisonTheNoLoadEstimate` pins this.

---

## Design decisions, and what was rejected

### The no-load estimate is allowed to forget

Estimating the no-load round trip is the hard half of a gradient controller. The
naive answer — keep the smallest RTT ever seen — fails in a specific, silent
way: one lucky 8 ms sample pins the floor forever, so when the device moves to a
network whose genuine floor is 60 ms the controller reads a gradient of 0.13,
concludes it is catastrophically congested, and collapses the limit for the rest
of the process's life. Throughput goes to almost nothing and no error is logged.

`DecayingMinimum` adopts any lower sample immediately (congestion relief must be
recognised at once) but inflates the held value every N samples, so a stale floor
drifts back toward reality on its own.

**Rejected: a sliding window of the last N samples.** O(N) memory *per transfer*,
and — the actual reason — it does not solve the problem any better. A 200-sample
window still holds a three-minute-old floor on a slow link, and shrinking the
window to fix that makes the floor noisy, which shows up as limit oscillation.

### Preemption is by admission, never by cancellation

An interactive upload that arrives behind 400 queued background chunks must go
first. The tempting implementation cancels in-flight background requests to free
a slot at once, and it is wrong: a cancelled chunk is bytes already pushed across
a metered connection that must be pushed again — the user's data and the user's
battery, spent twice, to save a few hundred milliseconds.

So an interactive item wins every *free* slot from the moment it is enqueued, and
nothing in flight is touched. The cost is bounded and stated: the interactive
item waits at most one background chunk's service time. **Which means chunk size
*is* preemption latency** — a coupling that is invisible from either
`ChunkPlanner` or `TransferScheduler` alone.

### Retry budgets are per-chunk, not global

A 300-chunk transfer with one permanently broken chunk — a byte range a proxy
mangles — has two possible behaviours. A **global** budget spends the transfer's
whole allowance on that one chunk and aborts with 40 chunks uploaded: classic
head-of-line blocking, where one bad unit of work starves 299 healthy ones. A
**per-chunk** budget lets it exhaust its own four attempts, marks it terminal, and
lands the other 299, then fails for a specific reportable reason instead of a
vague timeout.

A large global backstop is kept as a second bound, because per-chunk budgets
alone let a transfer whose *every* chunk is failing retry up to 1,200 times
(300 chunks x 4 attempts) before giving up — worse for the user and worse for the
server than failing fast. The default backstop is 1,024 attempts.

`RetryBudget.Shape.globalOnly` ships in the library rather than the test target
so the failure it causes can be demonstrated instead of asserted in prose.
`testAGlobalOnlyBudgetAbandonsAFlakyTransferThePerChunkShapeCompletes` runs both
shapes against the same flaky transport and shows one completing and one
abandoning healthy work.

### The manifest fingerprints the source

Resumption is only safe if the bytes have not changed. A user who re-exports a
video under the same name produces a payload the server will happily let you
finish uploading — and the result is a file whose first half is the old render
and second half the new one, **with a 200 from the server**. Silent, permanent
corruption.

So the manifest records a fingerprint at plan time and refuses to resume when it
differs. The fingerprint is total size plus a digest of a bounded 64 KiB prefix,
not the whole payload: a full digest is stronger and costs a complete read of a
2 GB file before the first byte moves, which the user experiences as the app
hanging. A prefix digest catches container and header changes, which is what a
re-encode actually changes, at a bounded cost.

### The digest is FNV-1a/64, never `Hasher`

Swift's `Hasher` is seeded per process, so the same bytes hash differently across
two launches of the same app — and a manifest written before a crash and read
after relaunch would report every chunk as changed, losing the entire point of
resumption.

The bug is nearly invisible, because the test that would catch it is the test
nobody writes: hashing the same bytes twice *inside one process* and asserting
the results match passes for `Hasher` too. `testDigestMatchesGoldenVectors`
checks against constants computed outside the process, which is the only form of
this test that has teeth.

### One actor, and a reentrancy rule you can grep for

Every other type here is a `struct` with no concurrency of its own. That is not
tidiness: actor isolation is cheap to add and expensive to reason about, because
once state lives behind an actor every read of it is a potential suspension point
and every sequence of reads is a potential interleaving.

Swift actors are reentrant, so the classic bug is check-then-act across a
suspension:

```swift
// WRONG — two callers can both pass the check before either increments.
guard inFlight < limiter.currentLimit else { return }
let receipt = try await transport.send(...)
inFlight += 1
```

`TransferCoordinator`'s rule: **every mutation of limiter, scheduler, budget and
manifest happens inside a synchronous private method with no `await` in it.** An
actor method with no suspension point cannot be interleaved, so the compiler
enforces atomicity for free. The network call lives in a `nonisolated static`
function that has no access to actor state at all — so a reviewer verifies the
rule by grepping for `await`, not by tracing control flow.

### Trapping arithmetic is centralised, not guarded case by case

The control loop converts measurements to counts, and every one of those
conversions traps: `Int(someDouble)` on `NaN`, on `±infinity`, or out of range;
`%` and `/` by zero; `Int.min / -1`; `+` and `*` on overflow. Sprinkling `guard`
statements at each site is how one gets missed, so every such operation goes
through `Saturating`. The `Int` ceiling is derived from `Int.max` rather than
written as a 64-bit literal, because `Int` is 32 bits on watchOS.

`SaturatingTests` is 10 tests of expressions that each trap if written the
obvious way — including `Saturating.int(Double(Int.max))`, where `Double(Int.max)`
rounds *up* to 2^63 and the naive conversion back traps.

---

## No vacuous tests

101 XCTest cases, and the ones that matter are the ones that would fail if the
implementation were gutted.

`LimiterInvariantCheck` states what "adaptive" has to mean — sustained queueing
must cut the limit to ≤ 70%, and clearing it must restore ≥ 80% — as a check that
accepts *any* `ConcurrencyLimiter`. The suite then runs it against
implementations that are wrong on purpose and requires it to reject them, by
name:

| subject | must | fails with |
|---|---|---|
| `GradientLimiter` | pass | — |
| `FixedLimiter(8)` | fail | `respondsToQueueing`, `respondsToDrops`, `probesUpward` |
| `MonotonicLimiter` | fail | `respondsToQueueing`, `respondsToDrops` — but **not** `probesUpward` |

That last row is the one that shows the check discriminates rather than
blanket-failing anything that is not `GradientLimiter`: `MonotonicLimiter` does
probe upward, so that invariant must be absent from its failures.

`testConcurrencyIsGenuinelyBoundedByTheLimit` exists for the same reason. A
coordinator that uploads serially would report entirely plausible limits, so a
witness transport records its own high-water mark and the test asserts real
overlap occurred *and* that the ceiling held. An earlier revision of this package
was serial and passed every other test.

---

## Using it

```swift
.package(url: "https://github.com/rajatslakhina/adaptive-transfer-kit.git", from: "1.0.0")
```

```swift
import AdaptiveTransfer

let coordinator = TransferCoordinator(
    transport: MyURLSessionTransport(),         // the one seam you implement
    planner: ChunkPlanner(),
    policy: .default,
    store: MyFileManifestStore()                // durable resumption state
)

let outcome = try await coordinator.upload(
    TransferRequest(
        transferID: asset.identifier,
        totalBytes: asset.byteCount,
        priority: .interactive,
        fingerprint: .init(hashing: asset.headerBytes)
    )
)

print(outcome.isComplete, outcome.finalLimit, outcome.terminallyFailedChunks)
```

`ChunkTransport` is the only protocol you have to conform to, and it is one
method. Implementations measure and report the round trip themselves — timing it
in the coordinator would include time spent waiting for the cooperative thread
pool, which is not a property of the network and would make the limiter shrink in
response to its own queueing.

### Modules

| module | what is in it | platforms |
|---|---|---|
| `AdaptiveTransfer` | the whole policy core, the coordinator, the simulation. No I/O, no `Foundation` beyond `pow`. | iOS 17+, macOS 14+, Linux |
| `AdaptiveTransferUI` | `TransferDashboardView` — the comparison above, live, with a slider for how hard the server degrades | iOS 17+, macOS 14+ |

---

## Running it

```bash
git clone https://github.com/rajatslakhina/adaptive-transfer-kit.git
cd adaptive-transfer-kit
swift build -Xswiftc -warnings-as-errors
swift test
```

`rm -rf .build` first if you want the warning gate to mean anything: `swift
build` on an up-to-date tree compiles nothing and still prints `Build complete!`.
That is why the flag lives in the Linux CI job rather than in a claim in this
file.

**Demo app:** _(added after the companion repo is pushed — see below)_

---

## Verification

Stated separately, because "it builds" and "it ran" are different facts and
conflating them is how a README stops being trustworthy.

* `swift build -Xswiftc -warnings-as-errors` on a cold tree (`.build` removed):
  **clean, zero warnings**, Swift 6.0.3, Linux x86_64.
* `swift test`: **101 tests, 0 failures.**
* Every number in the table above is printed by
  `CapacityExperimentTests.testPublishNumbersForTheReadme` and its neighbours
  assert the shape of each claim, so a regression in the control law turns those
  tests red rather than quietly making this file wrong.
* The numbers are produced by a **deterministic queueing model in virtual time,
  not by a device on a network.** The model is stated in `SimulatedServer`'s
  documentation so it can be argued with. It deliberately omits TCP slow start,
  TLS cost, HTTP/2 head-of-line blocking and bandwidth-as-distinct-from-
  concurrency — all of which make the fixed-limit case *worse*, so the comparison
  is conservative.
* See the [Actions tab](https://github.com/rajatslakhina/adaptive-transfer-kit/actions)
  for what CI enforces: a Linux job that builds with warnings as errors and runs
  the suite, and a macOS job that compiles for `generic/platform=iOS Simulator`.

## Licence

MIT.
