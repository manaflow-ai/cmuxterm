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
