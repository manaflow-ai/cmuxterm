# ``CmuxSocketObservability``

Release-visible slow-command observations and bounded main-thread hang diagnostics.

## Overview

The app constructs ``SocketCommandDescriptor`` once from the authorized method and
execution policy. ``SlowSocketCommandReporter`` forwards commands lasting at least
100 milliseconds to an injected ``SlowSocketCommandSink``. Descriptors contain no
request parameters or response payloads.

``MainThreadSocketCommandWatchdog`` monitors only a contiguous synchronous command
body on the main actor. Queue waits, asynchronous readiness waits, preparation, and
worker-side response encoding remain outside that scope. A one-shot Dispatch timer
runs on a separate utility queue, independent of the blocked main actor and the
cooperative task executor. Completion cancels it; the ticket serializes only the
short synchronous timer/completion state transitions, not command execution.

``MainThreadSocketCommandBacktraceCapturer`` allocates its address buffer before
entering a C-only suspend/read/resume boundary. That boundary uses bounded stack
storage, Mach calls, and pointer arithmetic, never heap allocation, Swift runtime
calls, locks, or symbolication. The sampled thread resumes before Swift constructs
arrays or resolves symbols. Sampling is best-effort and limited to 128 frames;
unreadable frames terminate the walk. Pointer-authentication bits are removed
before symbolication on arm64. The sampler refuses to suspend its own thread.

The app supplies unified-log and Sentry adapters. Tests exercise the state machine
without an app host and sample a real worker to verify capture and resumption.

## Tagged runtime verification

DEBUG builds provide bounded fault-injection probes through the authenticated
socket. `debug.socket_command_probe` deliberately parks the main thread for
`delay_ms` (default 1200, clamped to 0...2000) to verify hang, backtrace, recovery,
and slow-command records. `debug.socket_command_sync_probe` runs the legacy
synchronous dispatcher inside the async socket path; `protocol: "v1"` selects
`debug_socket_command_probe`, otherwise it selects the v2 probe. These probes do
not exist in Release builds, mutate no UI, and never activate or focus the app.
The blocking delay is the test stimulus, not a production synchronization path.

## Topics

### Slow commands

- ``SocketCommandDescriptor``
- ``SocketCommandObservation``
- ``SlowSocketCommandReporter``
- ``SlowSocketCommandSink``

### Main-thread watchdog

- ``MainThreadSocketCommandWatchdog``
- ``MainThreadSocketCommandWatchdogObservation``
- ``MainThreadSocketCommandWatchdogReporter``
- ``SocketCommandBacktraceCapturing``
- ``MainThreadSocketCommandBacktraceCapturer``
