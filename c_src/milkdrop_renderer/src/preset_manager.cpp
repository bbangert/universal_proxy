#include "preset_manager.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <utility>

namespace md {

PresetManager::PresetManager(std::vector<PresetEntry> entries,
                             std::set<std::string, std::less<>> skipped, Config config)
    : entries_(std::move(entries)), skipped_(std::move(skipped)), config_(config), rng_(config.seed) {}

bool PresetManager::eligible(size_t index) const {
    if (index >= entries_.size()) return false;
    const PresetEntry& e = entries_[index];
    if (skipped_.count(e.file) != 0) return false;
    if (e.high_frequency && !config_.high_frequency) return false;
    if (config_.gles2 && e.rpi3_skip) return false;
    return true;
}

size_t PresetManager::eligible_count() const {
    size_t n = 0;
    for (size_t i = 0; i < entries_.size(); i++) n += eligible(i) ? 1 : 0;
    return n;
}

const PresetEntry* PresetManager::current() const {
    return has_current_ ? &entries_[history_[cursor_]] : nullptr;
}

// A weighted random permutation (Efraimidis-Spirakis): each preset gets
// the key u^(1/w); sorting by key puts low-weight ones later on average.
void PresetManager::refill_bag() {
    std::uniform_real_distribution<double> uniform(0.0, 1.0);
    std::vector<std::pair<double, size_t>> keyed;
    for (size_t i = 0; i < entries_.size(); i++) {
        if (!eligible(i)) continue;
        const PresetEntry& e = entries_[i];
        const double weight =
            config_.gles2 && e.compile_ms > config_.expensive_compile_ms ? 0.5 : 1.0;
        double u = uniform(rng_);
        if (u <= 0) u = 1e-12;
        keyed.emplace_back(std::pow(u, 1.0 / weight), i);
    }
    // Highest key first; the bag pops from the back.
    std::sort(keyed.begin(), keyed.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    bag_.clear();
    for (const auto& [key, index] : keyed) bag_.push_back(index);
    // Don't repeat the current preset across a refill.
    if (has_current_ && bag_.size() > 1 && bag_.back() == history_[cursor_])
        std::swap(bag_.back(), bag_.front());
}

size_t PresetManager::draw() {
    while (true) {
        if (bag_.empty()) refill_bag();
        if (bag_.empty()) return entries_.size();
        size_t i = bag_.back();
        bag_.pop_back();
        // Entries can turn ineligible after the bag was filled.
        if (eligible(i)) return i;
    }
}

void PresetManager::push_history(size_t index) {
    if (has_current_) history_.resize(cursor_ + 1);  // drop the forward part
    history_.push_back(index);
    if (history_.size() > config_.history_limit) history_.erase(history_.begin());
    cursor_ = history_.size() - 1;
    has_current_ = true;
}

const PresetEntry* PresetManager::start(const std::string& locked_file) {
    refused_lock_.clear();
    if (!locked_file.empty()) {
        refused_lock_ = "unknown";
        for (size_t i = 0; i < entries_.size(); i++) {
            if (entries_[i].file != locked_file) continue;
            if (eligible(i)) {
                refused_lock_.clear();
                push_history(i);
                locked_ = true;
                return current();
            }
            const PresetEntry& e = entries_[i];
            refused_lock_ = skipped_.count(e.file) != 0 ? "skipped"
                            : excluded_high_frequency(i) ? "high_frequency"
                                                         : "rpi3_skip";
            break;
        }
    }
    locked_ = false;
    return rotate();
}

const PresetEntry* PresetManager::rotate() {
    size_t i = draw();
    if (i >= entries_.size()) return nullptr;
    push_history(i);
    return current();
}

const PresetEntry* PresetManager::next() {
    if (has_current_) {
        for (size_t c = cursor_ + 1; c < history_.size(); c++) {
            if (eligible(history_[c])) {
                cursor_ = c;
                return current();
            }
        }
    }
    return rotate();
}

const PresetEntry* PresetManager::prev() {
    if (!has_current_) return nullptr;
    for (size_t c = cursor_; c-- > 0;) {
        if (eligible(history_[c])) {
            cursor_ = c;
            return current();
        }
    }
    return nullptr;
}

bool PresetManager::skip(const std::string& file) {
    skipped_.insert(file);
    const PresetEntry* cur = current();
    return cur != nullptr && cur->file == file;
}

bool PresetManager::set_high_frequency(bool include) {
    config_.high_frequency = include;
    bag_.clear();  // re-deal with the new filter
    return high_frequency_on_screen();
}

bool PresetManager::excluded_high_frequency(size_t index) const {
    return index < entries_.size() && entries_[index].high_frequency && !config_.high_frequency;
}

void PresetManager::on_shown(const PresetEntry& entry, bool blend) {
    const PresetEntry* begin = entries_.data();
    const std::less<const PresetEntry*> before;
    if (before(&entry, begin) || !before(&entry, begin + entries_.size())) return;  // not ours
    const size_t index = static_cast<size_t>(&entry - begin);
    outgoing_ = blend ? showing_ : NONE;
    showing_ = index;
}

void PresetManager::on_blend_done() { outgoing_ = NONE; }

const PresetEntry* PresetManager::showing() const {
    return showing_ == NONE ? nullptr : &entries_[showing_];
}

const PresetEntry* PresetManager::outgoing() const {
    return outgoing_ == NONE ? nullptr : &entries_[outgoing_];
}

bool PresetManager::high_frequency_on_screen() const {
    return excluded_high_frequency(showing_) || excluded_high_frequency(outgoing_);
}

const PresetEntry* PresetManager::cut_target() {
    if (showing_ != NONE && eligible(showing_)) return &entries_[showing_];
    return rotate();
}

}  // namespace md
