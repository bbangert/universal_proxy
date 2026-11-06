// How one poll round's ready fds are handled. A landed flip is dispatched
// first, and only while the renderer still awaits one; commands run last.
// A command can consume the flip itself (`release` waits for it), and
// dispatching on the round's stale readiness after that would block in
// read() on the DRM fd for a flip that never comes.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

namespace md {

struct PollReady {
    bool flip = false;      // the DRM fd was readable
    bool commands = false;  // stdin was readable (or hung up)
};

template <class FlipAwaited, class Dispatch, class Commands>
void handle_poll_round(PollReady ready, FlipAwaited&& flip_awaited, Dispatch&& dispatch, Commands&& commands) {
    if (ready.flip && flip_awaited()) dispatch();
    if (ready.commands) commands();
}

}  // namespace md
