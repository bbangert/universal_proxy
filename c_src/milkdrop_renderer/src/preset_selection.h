// Picking the next preset that loads. Each failed candidate is skipped for
// the session and another is drawn. A warm-up stalls the render loop, so
// one call tries at most `batch` candidates: after that the caller carries
// on with what plays (frames, commands) and calls again.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include "preset_manager.h"

#include <functional>

namespace md {

enum class Attempt { Loaded, Failed, Abort };

enum class Selection {
    Switched,   // a candidate loaded
    Deferred,   // `batch` candidates failed; eligible ones remain
    Exhausted,  // nothing eligible is left
    Aborted,    // the attempt asked to stop (a fatal error)
};

// Tries `first`, then presets.rotate() picks, through `attempt`. A Failed
// candidate is presets.skip()ped before the next is drawn.
Selection select_preset(PresetManager& presets, const PresetEntry* first, int batch,
                        const std::function<Attempt(const PresetEntry&)>& attempt);

}  // namespace md
