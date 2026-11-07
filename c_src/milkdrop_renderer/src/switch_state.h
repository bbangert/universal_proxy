// The pending preset switch, GL-free: what the next switch is for, whether
// it must cut, whether frames may be rendered until it has happened, and
// whether a `take` waits for it.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "preset_selection.h"

namespace md {

enum class Switch { None, Rotate, Next, Prev, Eject, Retry };

class SwitchState {
public:
    Switch requested() const { return requested_; }
    bool pending() const { return requested_ != Switch::None; }

    // A command (next, prev) or the rotation timer. Never replaces a
    // pending eject or retry: the preset showing has to go first, and a
    // `prev` with nothing earlier would drop that switch.
    void request(Switch s) {
        if (requested_ == Switch::Eject || requested_ == Switch::Retry) return;
        requested_ = s;
    }
    // The preset showing must go (skipped, or filtered).
    void eject() { requested_ = Switch::Eject; }
    void eject_if_idle() {
        if (requested_ == Switch::None) requested_ = Switch::Eject;
    }
    // The preset showing hung the GPU: it is never rendered again. The
    // switch away cuts (projectM blends nothing with it) and no frame is
    // rendered until a replacement has loaded.
    void hang() {
        requested_ = Switch::Eject;
        force_cut_ = true;
    }

    // A switch starts: what it is for (the request is consumed).
    Switch begin() {
        const Switch s = requested_;
        requested_ = Switch::None;
        return s;
    }
    // Blend into the next preset, unless the switch must cut.
    bool smooth() const { return !force_cut_; }
    // A selection's outcome. `activated_failure`: a failed candidate holds
    // projectM's transition slot, so it is shown until the retry.
    void selected(Selection sel, bool activated_failure) {
        if (sel == Selection::Switched) force_cut_ = false;
        else if (sel == Selection::Deferred) force_cut_ = force_cut_ || activated_failure;
    }
    // A batch failed and eligible presets remain: try again next round.
    void retry(const char* cause) {
        requested_ = Switch::Retry;
        retry_cause_ = cause;
    }
    const char* retry_cause() const { return retry_cause_; }

    // projectM shows a hung or failed preset until the pending switch
    // replaces it: no frame may be rendered, none shown.
    bool holding_frames() const { return force_cut_ && requested_ != Switch::None; }

    // `take` arrived. True: take now. False: frames are held, so the take
    // waits until a replacement has loaded (take_due()).
    bool request_take() {
        if (!holding_frames()) return true;
        take_pending_ = true;
        return false;
    }
    // A take that waited and can run now (once).
    bool take_due() {
        if (!take_pending_ || holding_frames()) return false;
        take_pending_ = false;
        return true;
    }
    bool take_pending() const { return take_pending_; }
    void cancel_take() { take_pending_ = false; }

private:
    Switch requested_ = Switch::None;
    const char* retry_cause_ = "rotate";
    bool force_cut_ = false;
    bool take_pending_ = false;
};

// One loop round while not presenting: a selection batch while frames are
// held, then a `take` that waited for it. Selection exhausted or failed
// means `stopped()` (the exit is decided) and the take never runs.
template <class ApplySwitch, class Take, class Stopped>
void recovery_round(SwitchState& sw, ApplySwitch&& apply_switch, Take&& take, Stopped&& stopped) {
    if (sw.holding_frames()) apply_switch();
    if (!stopped() && sw.take_due()) take();
}

}  // namespace md
