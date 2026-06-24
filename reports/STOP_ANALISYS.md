# Stop Analysis

## Scope

This report analyzes every code path that can end, abort, or otherwise terminate an active motion/print workflow in the current codebase.

Covered flows:

- loaded G-code print in `char count` mode
- loaded G-code print in `RX logs` mode
- post-stop resume tracking after `Continue`
- rectangle `Loop` mode, because it is implemented by the same worker and has its own stop/termination semantics

Primary sources:

- `src/modules/serial_worker.rs`
- `src/main.rs`

## Terminology

The code currently has three different meanings of "termination", and they do not always line up.

### 1. Worker-level successful completion

This is the clean path where the worker emits `SerialEvent::PrintFinished`.

GUI effect:

- `print_active = false`
- `rx_buffer_used = 0`

Reference:

- `src/main.rs:308-310`

### 2. Worker-level aborted stop

This is the explicit stop path where the worker emits `SerialEvent::PrintAborted`.

GUI effect:

- `print_active = false`
- progress counters reset to `0`
- RX fill reset to `0`
- laser marker cleared
- status text says the controller is likely still in hold and needs reset

Reference:

- `src/main.rs:258-266`
- `src/main.rs:332`

### 3. Worker function returns without lifecycle event

Several failure paths only log an error and `return`, without emitting either `PrintFinished` or `PrintAborted`.

Important consequence:

- from the GUI point of view, the print may remain logically active because `send_loaded_gcode()` sets `print_active = true` before the worker starts, and only `PrintFinished` / `PrintAborted` clear it

Reference:

- `src/main.rs:158-177`
- `src/main.rs:304-310`
- `src/main.rs:332`

This is the most important structural observation in the current implementation.

## High-Level State Model

### G-code print start

When the user presses `Send`, the GUI immediately:

- clears `controller_reset_required`
- sets `print_active = true`
- resets progress state
- sends `SerialCommand::SendLoadedGcode`

Reference:

- `src/main.rs:158-177`

That means a later worker-side early return must emit a lifecycle event if the GUI is expected to leave the printing state.

### Explicit stop request

When the user presses `Stop` during a print:

- GUI sets `controller_reset_required = true`
- GUI calls `serial_worker.request_stop()`
- worker checks `stop_requested` and routes to `stop_stream()` for normal prints or `stop_loop_stream()` for loop mode

Reference:

- `src/main.rs:149-155`
- `src/modules/serial_worker.rs:122-124`

### Resume after stop

When the user presses `Continue`:

- worker sends GRBL cycle start `~`
- worker sets `track_position_until_idle = true`
- worker emits `PrintStarted` again
- completion later depends on seeing a GRBL status report with machine state `Idle`

Reference:

- `src/modules/serial_worker.rs:282-288`
- `src/modules/serial_worker.rs:371-395`

## Termination Conditions For Loaded G-code Prints

## A. `char count` mode

Worker entry point:

- `send_loaded_gcode_worker()`

Reference:

- `src/modules/serial_worker.rs:404-550`

### A1. Normal successful completion

Condition:

- all lines have been queued: `next_index >= lines.len()`
- all in-flight lines have been acknowledged: `in_flight.is_empty()`

Then the worker:

- logs stream statistics
- emits `PrintFinished`
- logs completion success

Reference:

- `src/modules/serial_worker.rs:478-480`
- `src/modules/serial_worker.rs:543-549`

This is the intended graceful termination for `char count`.

### A2. User stop during print

Condition:

- `stop_requested == true` either at loop top or during send loop

Then the worker calls `stop_stream()` and returns.

`stop_stream()`:

- sends feed hold `!`
- attempts spindle/laser stop override
- emits `PrintAborted`
- resets RX fill to zero
- logs `[Printing G-Code] aborted by stop request`
- clears the stop flag

Reference:

- `src/modules/serial_worker.rs:432-435`
- `src/modules/serial_worker.rs:439-442`
- `src/modules/serial_worker.rs:1129-1163`

This is the only explicit aborted termination path for a normal G-code print.

### A3. Empty file

Condition:

- `lines.is_empty()`

Worker behavior:

- emits progress `0/0`
- logs `No G-code loaded.`
- returns

Reference:

- `src/modules/serial_worker.rs:410-413`

Important implication:

- no `PrintFinished`
- no `PrintAborted`

Because the GUI already set `print_active = true` before dispatch, pressing `Send` with no loaded G-code can leave the GUI in a false "printing" state.

Reference:

- `src/main.rs:158-177`

### A4. Oversized G-code line

Condition:

- `line.len() + 1 > GRBL_RX_LIMIT`

Worker behavior:

- logs `Line N too long for GRBL RX buffer`
- returns

Reference:

- `src/modules/serial_worker.rs:445-453`

Termination classification:

- worker-side failure return
- not a clean finish
- not an explicit abort

GUI implication:

- `print_active` remains true unless some later unrelated event clears it

### A5. Serial send failure while transmitting

Condition:

- `bridge.send_line(&line)` returns `Err`

Worker behavior:

- logs `Send failed: ...`
- returns

Reference:

- `src/modules/serial_worker.rs:459-474`

Same lifecycle problem:

- no `PrintFinished`
- no `PrintAborted`

### A6. Device reports `error:...` for an in-flight line

Condition:

- polled reply line starts with `error:`
- there is a matching in-flight line, or error arrives with empty queue

Worker behavior:

- logs either `Device error on line ...` or `Device error with empty in-flight queue`
- returns

Reference:

- `src/modules/serial_worker.rs:499-517`

This is a print termination from the controller side, but the GUI does not receive a terminal lifecycle event.

### A7. Acknowledgement stall timeout

Condition:

- no progress for more than `STREAM_STALL_TIMEOUT_SECS` (`30 s`)

Worker behavior:

- logs `Stream stalled waiting for acknowledgements.`
- returns

Reference:

- `src/modules/serial_worker.rs:482-489`

Again:

- worker stops the print loop
- GUI is not told that the print has ended

### A8. Poll/read failure inside the sender

Condition:

- `bridge.poll_reply(STREAM_POLL_MS)` returns `Err`

Worker behavior:

- logs `Send failed: ...`
- returns

Reference:

- `src/modules/serial_worker.rs:491-539`

This is logically a transport failure termination, but it is not modeled as finish or abort.

## B. `RX logs` mode

Worker entry point:

- `send_loaded_gcode_worker_rx()`

Reference:

- `src/modules/serial_worker.rs:552-804`

`RX logs` has more termination conditions because it adds status polling and a post-send RX-empty debounce.

### B1. Normal successful completion after RX-empty debounce

Condition:

- all lines have been sent: `next_index >= lines.len()`
- then `waiting_for_rx_empty_after_send = true`
- then `rx_empty_since` remains active long enough that RX fill stays at `0` for `RX_EMPTY_FINISH_MS` (`1000 ms`)

Worker behavior:

- logs that RX fill stayed at `0%` long enough
- stops the status thread
- logs stream statistics
- emits `RxBufferFill { used: 0 }`
- emits `PrintFinished`
- logs successful completion

Reference:

- `src/modules/serial_worker.rs:674-685`
- `src/modules/serial_worker.rs:747-762`
- `src/modules/serial_worker.rs:785-803`

This is the intended graceful termination for `RX logs`.

### B2. User stop during print

Condition:

- `stop_requested == true` either at loop top or during the send loop

Worker behavior:

- stops and joins the status helper thread
- calls `stop_stream()`
- returns

Reference:

- `src/modules/serial_worker.rs:594-600`
- `src/modules/serial_worker.rs:611-616`
- `src/modules/serial_worker.rs:1129-1163`

Outcome:

- explicit `PrintAborted`

### B3. Empty file

Condition:

- `lines.is_empty()`

Worker behavior:

- emits progress `0/0`
- logs `No G-code loaded.`
- returns

Reference:

- `src/modules/serial_worker.rs:558-561`

GUI implication:

- same stale `print_active` risk as `char count`

### B4. Status query send failure

Condition:

- helper tick arrives
- `bridge.send_status_query()` returns `Err`

Worker behavior:

- stops the helper thread
- logs `Status query failed: ...`
- returns

Reference:

- `src/modules/serial_worker.rs:602-608`

Termination classification:

- RX-mode-specific failure termination
- no `PrintFinished`
- no `PrintAborted`

### B5. Oversized G-code line

Condition:

- `line.len() + 1 > GRBL_RX_LIMIT`

Worker behavior:

- stops the helper thread
- logs oversized-line error
- returns

Reference:

- `src/modules/serial_worker.rs:618-629`

### B6. Serial send failure while transmitting

Condition:

- `bridge.send_line(&line)` returns `Err`

Worker behavior:

- stops helper thread
- logs `Send failed: ...`
- returns

Reference:

- `src/modules/serial_worker.rs:650-669`

### B7. RX-mode stall timeout

Condition:

- no progress for more than `30 s`

Worker behavior:

- stops helper thread
- logs `RX-status stream stalled waiting for acknowledgements.`
- returns

Reference:

- `src/modules/serial_worker.rs:688-697`

### B8. Device reports `error:...`

Condition:

- a reply line starts with `error:`

Worker behavior:

- stops helper thread
- logs controller error
- returns

Reference:

- `src/modules/serial_worker.rs:707-732`

### B9. Poll/read failure inside the RX sender

Condition:

- `bridge.poll_reply(STREAM_POLL_MS)` returns `Err`

Worker behavior:

- stops helper thread
- logs `Send failed: ...`
- returns

Reference:

- `src/modules/serial_worker.rs:776-780`

### B10. RX-empty debounce never starts or never completes

This is not a separate `return` branch, but it matters for practical termination.

The print only finishes after:

- send progress is already `100%`
- a parsed status report provides RX information
- RX usage becomes exactly `0`
- that `0` holds continuously for `1000 ms`

Reference:

- `src/modules/serial_worker.rs:674-685`
- `src/modules/serial_worker.rs:739-762`

Implication:

- if the controller never reports usable RX fields after the send phase, the worker can remain dependent on timeout rather than clean completion
- eventual result is likely the RX-mode stall timeout, not `PrintFinished`

This is an intended design tradeoff, not necessarily a bug, but it is still a termination condition dependency.

## C. Resume-Tracking Termination After `Continue`

This path matters because after a user stop, the original sender is not restarted. The app enters a different completion mechanism.

### C1. Successful completion after resume

Flow:

1. user presses `Continue`
2. worker sends `~`
3. worker sets `track_position_until_idle = true`
4. worker emits `PrintStarted`
5. worker polls status in the outer `worker_loop`
6. `handle_resume_tracking_reply()` waits for a parsed status report with machine state `Idle`
7. when `Idle` is seen, worker emits `PrintFinished`

Reference:

- `src/modules/serial_worker.rs:282-288`
- `src/modules/serial_worker.rs:153-182`
- `src/modules/serial_worker.rs:371-395`

Actual termination condition:

- resumed motion is considered finished only when a GRBL status report says `Idle`

### C2. Resume tracking interrupted by status query failure

Condition:

- outer worker loop tries to send periodic `?`
- `bridge.send_status_query()` fails

Worker behavior:

- logs `Status query failed: ...`
- sets `track_position_until_idle = false`
- does not emit `PrintFinished`
- does not emit `PrintAborted`

Reference:

- `src/modules/serial_worker.rs:153-166`

Result:

- resume-tracking stops silently from a lifecycle standpoint
- `print_active` may remain true in the GUI

### C3. Resume tracking interrupted by serial read failure

Condition:

- outer `worker_loop` polling fails while `track_position_until_idle` is active

Worker behavior:

- logs `Serial error: ...`
- disconnects the bridge
- clears RX fill
- emits `Connected(false)`
- disables resume tracking
- does not emit `PrintFinished`
- does not emit `PrintAborted`

Reference:

- `src/modules/serial_worker.rs:169-197`

This is one of the clearest state mismatches in the code:

- transport is gone
- resume tracking is gone
- GUI may still think the print is active

## D. Transport-Level Termination Outside The Sender Functions

These conditions are not tied to a single streaming mode and can cut across states.

### D1. Manual disconnect while a print is active

Condition:

- user presses `Connect` while already connected, which sends `SerialCommand::Disconnect`

Worker behavior:

- clears `track_position_until_idle`
- disconnects bridge
- resets RX fill
- logs `Disconnected.`
- emits `Connected(false)`

Reference:

- `src/main.rs:439-443`
- `src/modules/serial_worker.rs:234-243`

Important consequence:

- no `PrintFinished`
- no `PrintAborted`

So a manual disconnect during an active print terminates transport, but not the GUI print lifecycle.

### D2. Background serial error in `worker_loop`

Condition:

- any `bridge.poll_reply()` call in the outer worker loop returns `Err`

Worker behavior:

- logs `Serial error: ...`
- disconnects
- resets RX fill
- emits `Connected(false)`

Reference:

- `src/modules/serial_worker.rs:175-197`

Again, this is physical/transport termination without explicit print termination semantics.

## Termination Conditions For Loop Mode

Loop mode is not a loaded-G-code print, but it is a motion workflow with its own stop/finish behavior and shares the same stop flag.

Worker entry point:

- `loop_rectangle_worker()`

Reference:

- `src/modules/serial_worker.rs:806-1034`

### E1. Invalid zero-size rectangle

Condition:

- width or height is zero

Worker behavior:

- logs invalid rectangle
- emits `LoopStopped`
- returns

Reference:

- `src/modules/serial_worker.rs:819-825`

This is a clean loop termination before motion begins.

### E2. Setup command failure before looping

Conditions:

- `send_blocking_line("G90")` fails
- or initial move to rectangle start fails

Worker behavior:

- logs setup/start move failure
- emits `LoopStopped`
- returns

Reference:

- `src/modules/serial_worker.rs:855-865`

These are cleaner than print failures because they do emit a lifecycle event.

### E3. User stop during loop

Condition:

- `stop_requested == true`

Worker behavior after loop exit:

- calls `stop_loop_stream()`
- sends hold `!`
- sends spindle/laser stop override
- sends soft reset `Ctrl-X`
- logs stop/reset completion
- emits `LoopStopped`
- resets RX fill
- returns

Reference:

- `src/main.rs:204-208`
- `src/modules/serial_worker.rs:889-892`
- `src/modules/serial_worker.rs:903-906`
- `src/modules/serial_worker.rs:1013-1020`
- `src/modules/serial_worker.rs:1036-1077`

Loop mode is stricter than print mode:

- stop includes automatic soft reset
- there is no separate "held, waiting for user reset" state

### E4. Loop status query failure

Condition:

- periodic `?` send fails during loop mode

Worker behavior:

- logs `Loop status query failed: ...`
- breaks out of loop
- then executes normal non-stop cleanup
- sends spindle stop
- emits `LoopStopped`
- resets RX fill
- logs `Loop rectangle stopped.`

Reference:

- `src/modules/serial_worker.rs:894-900`
- `src/modules/serial_worker.rs:1022-1033`

### E5. Loop send failure

Condition:

- `bridge.send_line(line)` fails during loop streaming

Worker behavior:

- logs `Loop move failed: ...`
- breaks out of loop
- then executes normal non-stop cleanup

Reference:

- `src/modules/serial_worker.rs:920-937`
- `src/modules/serial_worker.rs:1022-1033`

### E6. Loop stall timeout

Condition:

- no activity for more than `30 s`

Worker behavior:

- logs `Loop stream stalled waiting for controller progress.`
- breaks
- then performs normal non-stop cleanup

Reference:

- `src/modules/serial_worker.rs:941-948`
- `src/modules/serial_worker.rs:1022-1033`

### E7. Loop device `error:...`

Condition:

- loop reply line starts with `error:`

Worker behavior:

- logs `Loop device error: ...`
- breaks
- then performs normal non-stop cleanup

Reference:

- `src/modules/serial_worker.rs:958-977`
- `src/modules/serial_worker.rs:1022-1033`

### E8. Loop receive failure

Condition:

- `bridge.poll_reply(STREAM_POLL_MS)` returns `Err`

Worker behavior:

- logs `Loop receive failed: ...`
- breaks
- then performs normal non-stop cleanup

Reference:

- `src/modules/serial_worker.rs:950-1007`
- `src/modules/serial_worker.rs:1022-1033`

Important distinction versus print mode:

- most loop failure exits still end with `LoopStopped`
- loop lifecycle handling is more consistent than loaded-G-code print lifecycle handling

## GUI-Side Consequences By Termination Type

### Clean print completion

Triggered by:

- `PrintFinished`

GUI result:

- `print_active = false`
- RX fill cleared
- progress counters remain at last values, usually showing finished state

Reference:

- `src/main.rs:304-315`

### Explicit print abort

Triggered by:

- `PrintAborted`

GUI result:

- `print_active = false`
- progress counters reset to zero
- status text tells user to flush/reset

Reference:

- `src/main.rs:258-266`
- `src/main.rs:332`

### Loop termination

Triggered by:

- `LoopStopped`

GUI result:

- `loop_active = false`
- loop selection state cleared
- `controller_reset_required = false`
- status becomes `Loop rectangle stopped.` unless a print is still active

Reference:

- `src/main.rs:323-330`

### Disconnect without print lifecycle event

Triggered by:

- `Connected(false)` only

GUI result:

- serial status changes to disconnected
- RX fill clears
- `print_active` is unchanged

Reference:

- `src/main.rs:298-303`

This is why disconnect and some serial errors can terminate the physical job path without terminating the GUI print state.

## Summary Matrix

### Loaded G-code print, `char count`

- Clean finish: yes, via empty in-flight queue and `PrintFinished`
- User stop: yes, via `PrintAborted`
- Empty file: returns without lifecycle event
- Oversized line: returns without lifecycle event
- Send failure: returns without lifecycle event
- Device error: returns without lifecycle event
- Stall timeout: returns without lifecycle event
- Read/poll failure: returns without lifecycle event

### Loaded G-code print, `RX logs`

- Clean finish: yes, after `100%` send plus `RX=0` for `1000 ms`, then `PrintFinished`
- User stop: yes, via `PrintAborted`
- Empty file: returns without lifecycle event
- Status query failure: returns without lifecycle event
- Oversized line: returns without lifecycle event
- Send failure: returns without lifecycle event
- Device error: returns without lifecycle event
- Stall timeout: returns without lifecycle event
- Read/poll failure: returns without lifecycle event

### Resume tracking after `Continue`

- Clean finish: yes, on GRBL `Idle`, then `PrintFinished`
- Status query failure: tracking stops without lifecycle event
- Read failure/disconnect: tracking stops without lifecycle event

### Loop mode

- Invalid rectangle: `LoopStopped`
- Setup/start move failure: `LoopStopped`
- User stop: `LoopStopped` after hold + spindle stop + soft reset
- Status query failure: `LoopStopped`
- Send failure: `LoopStopped`
- Device error: `LoopStopped`
- Stall timeout: `LoopStopped`
- Read failure: `LoopStopped`

## Main Findings

### 1. Print termination semantics are inconsistent across modes

Loop mode consistently emits `LoopStopped` on both normal and failure exits.

Loaded-G-code print modes do not do the same. Many failure paths only log and return.

### 2. `print_active` can become stale

Because the GUI sets `print_active = true` before dispatch and only clears it on `PrintFinished` / `PrintAborted`, the following cases can leave the GUI in a false active-print state:

- empty G-code send
- oversized line
- send failure
- controller `error:...`
- stall timeout
- RX status query failure
- serial read failure
- manual disconnect during print
- resume-tracking failure after `Continue`

### 3. Manual disconnect is transport termination, not print termination

The disconnect path emits `Connected(false)` but not a print lifecycle event, so it does not fully terminate the print from the GUI state model.

### 4. `RX logs` completion is intentionally stricter than `char count`

`char count` finishes when all queued lines are acknowledged locally.

`RX logs` finishes later, only after:

- all lines are sent
- RX fill is observed as zero
- that zero persists for `1000 ms`

This is the main intended behavioral difference in completion semantics.

## Practical Conclusion

If "print termination" is defined as "the worker stops doing work", then there are many termination paths in both print modes.

If "print termination" is defined as "the GUI is reliably informed that the print has ended", then only these paths are currently complete:

- successful `char count` finish
- successful `RX logs` finish
- explicit user stop through `stop_stream()` producing `PrintAborted`
- successful resume-tracking finish after `Continue`

Most other print-side failures terminate execution but do not terminate the GUI lifecycle cleanly.
