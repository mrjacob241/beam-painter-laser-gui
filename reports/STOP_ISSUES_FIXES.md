# Stop Issues Fixes

## Scope

This document proposes concrete fixes for the lifecycle problem identified in `reports/STOP_ANALISYS.md`.

The core issue is:

- several print-side failure paths terminate worker activity without emitting a terminal lifecycle event
- the GUI therefore can remain stuck in `print_active = true`

This affects:

- loaded G-code print in `char count` mode
- loaded G-code print in `RX logs` mode
- resume tracking after `Continue`
- disconnect and transport-error cases during an active print

## Fix 1: Introduce A Single Typed Print-Termination Event

### Proposal

Replace the current partial lifecycle model:

- `PrintStarted`
- `PrintFinished`
- `PrintAborted`

with a stronger terminal event, for example:

```rust
pub enum PrintEndReason {
    Completed,
    StoppedByUser,
    EmptyInput,
    LineTooLong,
    SendFailed,
    DeviceError,
    StallTimeout,
    StatusQueryFailed,
    SerialReadFailed,
    Disconnected,
}

pub enum SerialEvent {
    // ...
    PrintStarted,
    PrintEnded {
        reason: PrintEndReason,
        detail: Option<String>,
    },
}
```

### Why this is the best fix

- every termination path becomes explicit
- GUI cleanup becomes uniform
- logs stop being the only source of truth
- user stop, protocol failure, disconnect, and successful completion are distinguished cleanly
- future print modes can reuse the same termination model

### What changes in practice

Every return path in:

- `send_loaded_gcode_worker()`
- `send_loaded_gcode_worker_rx()`
- resume-tracking logic in `worker_loop()`

must emit `PrintEnded { ... }` before returning.

### GUI behavior

The GUI should react to `PrintEnded` by:

- setting `print_active = false`
- clearing RX state
- clearing or preserving progress according to the reason
- updating status text based on the reason
- clearing `controller_reset_required` only when appropriate

## Fix 2: Minimum Patch With Existing Event Model

### Proposal

If a full event-model refactor is considered too large right now, keep the current event types and emit `PrintAborted` on every failure return path that currently only logs and returns.

That includes failures such as:

- empty input
- line too long
- send failure
- device `error:...`
- stall timeout
- RX status query failure
- serial read failure
- disconnect while a print is active

### Advantages

- small patch
- low mechanical complexity
- fixes the stale `print_active` bug quickly

### Limitations

- collapses very different causes into the same "aborted" bucket
- user stop and transport failure remain indistinguishable at the lifecycle layer
- logs are still required to understand what actually happened

### When this is acceptable

This is a good short-term fix if the immediate goal is:

- prevent stale GUI state
- avoid getting stuck in fake printing mode

without reshaping the whole event model.

## Fix 3: Centralize Print Finalization In Worker Helpers

### Proposal

Introduce worker-side helper functions so every sender exit goes through a single controlled path.

Example shape:

```rust
fn finish_print_success(tx_evt: &Sender<SerialEvent>) {
    // emit RX reset, lifecycle event, success log
}

fn finish_print_failure(
    tx_evt: &Sender<SerialEvent>,
    reason: PrintEndReason,
    detail: impl Into<String>,
) {
    // emit RX reset, lifecycle event, failure log
}
```

### Why this matters

- avoids missing a branch
- keeps lifecycle, RX reset, and log emission consistent
- reduces copy-paste in both print modes
- makes later maintenance safer

### Where it applies

The helper should be used by:

- `send_loaded_gcode_worker()`
- `send_loaded_gcode_worker_rx()`
- resume-tracking termination paths
- disconnect/error paths in `worker_loop()` when a print is active

## Fix 4: Make `PrintStarted` The Only Source Of Truth For Active Print State

### Current problem

The GUI sets `print_active = true` before the worker has actually started the print:

- `send_loaded_gcode()` sets `print_active = true`
- then the command is sent to the worker

If the worker immediately returns due to:

- empty file
- invalid line length
- send failure

the GUI may remain stuck active unless a terminal event is emitted later.

### Proposal

Change the GUI flow so that:

- `send_loaded_gcode()` does not set `print_active = true`
- only `SerialEvent::PrintStarted` sets `print_active = true`

Optional:

- add a lightweight `starting print...` status line if the UI needs immediate feedback

### Benefits

- removes one source of stale state
- restores event-driven authority to the worker
- empty-input cases become much safer even before a full lifecycle refactor

### Important note

This fix is useful, but not sufficient on its own.

If a print starts correctly and later fails without a terminal event, the GUI can still remain stuck active. So this should be combined with Fix 1 or Fix 2.

## Fix 5: Explicitly Terminate Prints On Disconnect

### Current problem

Manual disconnect and transport errors currently emit:

- `Connected(false)`
- RX reset

but do not emit a print lifecycle termination.

That means the physical transport can be gone while the GUI still shows an active print.

### Proposal

Whenever disconnect occurs during an active print or resume-tracking phase:

- emit a print terminal event first or alongside disconnect
- use a reason such as `Disconnected` or `SerialReadFailed`

This should apply to:

- explicit `SerialCommand::Disconnect`
- outer `worker_loop()` serial read failures
- any path that forces `bridge.disconnect()` while a print is logically active

### Benefits

- transport state and print state stay aligned
- prevents "disconnected but still printing" GUI contradictions

## Fix 6: Treat Resume Tracking As A Real Print Lifecycle Phase

### Current problem

After `Continue`, the original sender is no longer running. Completion depends on resume tracking in the outer worker loop.

That path currently finishes cleanly only if:

- a status report arrives
- machine state becomes `Idle`

But failures such as:

- status query failure
- serial read failure
- disconnect during resume tracking

do not emit a print terminal event.

### Proposal

Promote resume tracking to a fully modeled print phase:

- entering it emits `PrintStarted` or a more specific `PrintResumed`
- leaving it must always emit a terminal event, success or failure

### Benefits

- stop/recover flow becomes lifecycle-consistent
- resumed prints cannot remain visually active forever after transport loss

## Fix 7: Separate User Stop From Failure In GUI Messaging

### Proposal

If typed end reasons are introduced, map them to clearer user-facing status text.

Examples:

- `Completed`: "Print completed successfully."
- `StoppedByUser`: "Job stopped. Controller is likely in hold; reset or continue as needed."
- `DeviceError`: "Controller reported an error during streaming."
- `StatusQueryFailed`: "Print tracking stopped because status polling failed."
- `Disconnected`: "Print terminated because the serial connection was lost."

### Why this matters

Right now the UI only has strong language for the explicit stop path. Failure cases often appear only in the serial log.

Clear reason-based status text would:

- reduce operator confusion
- make debugging easier
- reduce reliance on scrolling through console history

## Fix 8: Preserve Or Reset Progress Intentionally Based On End Reason

### Current behavior

- `PrintFinished` leaves progress values as they were
- `PrintAborted` resets progress counters to `0`

This is simple, but weak for diagnostics.

### Proposal

Tie progress cleanup to the termination reason.

Suggested policy:

- `Completed`: preserve final `100%` progress
- `StoppedByUser`: preserve current progress snapshot
- `DeviceError` / `SendFailed` / `Disconnected`: preserve last known progress so the failure point is visible
- `EmptyInput`: reset to `0`

### Benefits

- more informative UI
- easier operator understanding of where the print stopped
- better post-failure debugging

## Fix 9: Add A Small Internal Print-State Machine

### Proposal

Instead of relying on a single boolean plus scattered assumptions, model worker-side print state explicitly.

Example:

```rust
enum ActivePrintState {
    Idle,
    SendingCharCount,
    SendingRxLogs,
    Held,
    ResumeTracking,
}
```

### Why this helps

- disconnect handlers can know whether a print is active
- lifecycle events become easier to emit correctly
- stop/continue/reset behavior becomes less implicit
- future features like pause/retry become easier to implement

### Tradeoff

This is a larger refactor than the others, so it is not the first fix to ship unless the code is already being reorganized.

## Recommended Rollout Order

### Option A: Best Long-Term Solution

1. introduce `PrintEnded { reason, detail }`
2. centralize worker finalization in helper functions
3. move GUI `print_active = true` logic to `PrintStarted` only
4. terminate prints explicitly on disconnect and resume-tracking failures
5. improve status messages and progress retention by reason

This produces the cleanest architecture.

### Option B: Pragmatic Short-Term Repair

1. emit `PrintAborted` on every print failure return path
2. stop setting `print_active = true` before `PrintStarted`
3. emit `PrintAborted` on disconnect during active print
4. emit `PrintAborted` when resume tracking fails

This is the fastest path to removing the stuck-print bug.

## Recommendation

The best engineering choice is Fix 1 plus Fix 3 plus Fix 4.

That combination:

- solves the stale GUI state bug
- gives complete termination coverage
- keeps termination reasons explicit
- avoids future regressions when new print behaviors are added

If a smaller patch is preferred first, implement Fix 2 immediately and follow up later with the typed terminal-event refactor.
