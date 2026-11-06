#include "preset_selection.h"

namespace md {

Selection select_preset(PresetManager& presets, const PresetEntry* first, int batch,
                        const std::function<Attempt(const PresetEntry&)>& attempt) {
    const PresetEntry* entry = first;
    for (int tried = 0; entry != nullptr;) {
        switch (attempt(*entry)) {
            case Attempt::Loaded: return Selection::Switched;
            case Attempt::Abort: return Selection::Aborted;
            case Attempt::Failed: break;
        }
        presets.skip(entry->file);
        if (++tried >= batch) break;
        entry = presets.rotate();
    }
    return presets.eligible_count() == 0 ? Selection::Exhausted : Selection::Deferred;
}

SkipCause activation_failure(std::string_view reported, std::string_view last_error) {
    return {"load_failed", std::string(reported.empty() ? last_error : reported)};
}

}  // namespace md
