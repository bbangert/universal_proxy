#include "preset_manager.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <utility>

namespace md {

PresetManager::PresetManager(std::vector<PresetEntry> entries,
                             std::set<std::string, std::less<>> skipped, Config config)
    : skipped_(std::move(skipped)), config_(config), rng_(config.seed) {
    for (PresetEntry& e : entries) {
        const bool duplicate = !by_id_.emplace(e.file, entries_.size()).second;
        entries_.push_back(std::move(e));
        gone_.push_back(duplicate ? 1 : 0);  // only the first of an id plays
    }
}

bool PresetManager::eligible(size_t index) const {
    if (index >= entries_.size() || gone_[index] != 0) return false;
    const PresetEntry& e = entries_[index];
    if (skipped_.count(e.file) != 0) return false;
    if (e.high_frequency && !config_.high_frequency) return false;
    if (config_.gles2 && e.rpi3_skip) return false;
    return true;
}

const char* PresetManager::refusal(size_t index) const {
    if (index >= entries_.size() || gone_[index] != 0) return "unknown";
    if (skipped_.count(entries_[index].file) != 0) return "skipped";
    if (excluded_high_frequency(index)) return "high_frequency";
    if (config_.gles2 && entries_[index].rpi3_skip) return "rpi3_skip";
    return "";
}

size_t PresetManager::eligible_count() const {
    size_t n = 0;
    for (size_t i = 0; i < entries_.size(); i++) n += eligible(i) ? 1 : 0;
    return n;
}

bool PresetManager::hidden(size_t index) const {
    return index < entries_.size() && selection_.hidden.count(entries_[index].file) != 0;
}

bool PresetManager::in_pool(size_t index, Pool pool) const {
    if (!eligible(index)) return false;
    switch (pool) {
        case Pool::Playlist: return !hidden(index) && selection_.playlist.count(entries_[index].file) != 0;
        case Pool::Unhidden: return !hidden(index);
        case Pool::Eligible: return true;
    }
    return false;
}

PresetManager::PoolInfo PresetManager::rotation_pool() const {
    size_t playlist = 0, unhidden = 0, all = 0;
    for (size_t i = 0; i < entries_.size(); i++) {
        if (!eligible(i)) continue;
        all++;
        if (hidden(i)) continue;
        unhidden++;
        if (selection_.playlist.count(entries_[i].file) != 0) playlist++;
    }
    PoolInfo info;
    if (selection_.playlist_enabled && playlist > 0) {
        info.pool = Pool::Playlist;
        info.size = playlist;
        return info;
    }
    info.playlist_fallback = selection_.playlist_enabled;
    if (unhidden > 0) {
        info.pool = Pool::Unhidden;
        info.size = unhidden;
        return info;
    }
    info.pool = Pool::Eligible;
    info.size = all;
    info.hidden_fallback = all > 0;
    return info;
}

PresetManager::PoolInfo PresetManager::set_selection(UserSelection selection) {
    selection_ = std::move(selection);
    bag_.clear();  // re-deal with the new selection
    return rotation_pool();
}

PresetManager::UserReload PresetManager::set_user_presets(std::vector<PresetEntry> user) {
    UserReload r;
    std::set<size_t> listed;
    for (PresetEntry& e : user) {
        if (!is_user_id(e.file)) continue;
        auto it = by_id_.find(e.file);
        if (it == by_id_.end()) {
            it = by_id_.emplace(e.file, entries_.size()).first;
            entries_.push_back(std::move(e));
            gone_.push_back(0);
            r.added++;
        } else {
            if (listed.count(it->second) != 0) continue;  // a duplicate in `user`
            // In place: a pointer to the entry reads the new fields.
            entries_[it->second] = std::move(e);
            if (gone_[it->second] != 0) r.added++;
            gone_[it->second] = 0;
        }
        listed.insert(it->second);
    }
    for (const auto& [id, index] : by_id_) {
        if (!is_user_id(id) || gone_[index] != 0) continue;
        if (listed.count(index) == 0) {
            gone_[index] = 1;
            r.removed++;
        } else {
            r.presets++;
        }
    }
    bag_.clear();  // re-deal with the new catalogue
    r.cut = high_frequency_on_screen();
    return r;
}

const PresetEntry* PresetManager::current() const {
    return has_current_ ? &entries_[history_[cursor_]] : nullptr;
}

// A deal: one ticket per preset of the pool, favourite_tickets per
// favourite, in a weighted random order (Efraimidis-Spirakis: each ticket
// gets the key u^(1/w), so low-weight presets come later on average).
// Weight only orders a deal; tickets set how often a preset plays in it.
void PresetManager::refill_bag() {
    bag_pool_ = rotation_pool().pool;
    std::uniform_real_distribution<double> uniform(0.0, 1.0);
    std::vector<std::pair<double, size_t>> keyed;
    for (size_t i = 0; i < entries_.size(); i++) {
        if (!in_pool(i, bag_pool_)) continue;
        const PresetEntry& e = entries_[i];
        const double weight = config_.gles2 && e.compile_ms > config_.expensive_compile_ms ? 0.5 : 1.0;
        const size_t tickets = selection_.favourites.count(e.file) != 0 ? config_.favourite_tickets : 1;
        for (size_t t = 0; t < tickets; t++) {
            double u = uniform(rng_);
            if (u <= 0) u = 1e-12;
            keyed.emplace_back(std::pow(u, 1.0 / weight), i);
        }
    }
    // Highest key first; the bag pops from the back.
    std::sort(keyed.begin(), keyed.end(), [](const auto& a, const auto& b) { return a.first < b.first; });
    bag_.clear();
    for (const auto& [key, index] : keyed) bag_.push_back(index);
    // Spread a favourite's tickets: no two of a preset back to back where
    // a later ticket of another can go in between.
    for (size_t p = bag_.size(); p-- > 1;) {
        if (bag_[p - 1] != bag_[p]) continue;
        for (size_t q = p - 1; q-- > 0;) {
            if (bag_[q] != bag_[p]) {
                std::swap(bag_[p - 1], bag_[q]);
                break;
            }
        }
    }
}

// Never the playing preset twice in a row, across deals too, unless it is
// all the pool holds.
size_t PresetManager::draw() {
    bool fresh = false;
    while (true) {
        if (bag_.empty()) {
            refill_bag();
            fresh = true;
        }
        if (bag_.empty()) return entries_.size();
        size_t i = bag_.back();
        // Entries can turn ineligible after the bag was filled; a pool
        // emptied that way falls back at the next deal.
        if (!in_pool(i, bag_pool_)) {
            bag_.pop_back();
            continue;
        }
        if (has_current_ && i == history_[cursor_]) {
            size_t k = bag_.size() - 1;
            while (k-- > 0 && (bag_[k] == i || !in_pool(bag_[k], bag_pool_))) {}
            if (k < bag_.size()) {
                std::swap(bag_[k], bag_.back());
                i = bag_.back();
            } else if (!fresh) {
                // Only its own tickets are left: they go into the next
                // deal, anywhere but its first pick, at most as many as
                // it holds per deal. With no other preset in the pool they
                // are dropped (it just repeats). Bounded either way: the
                // no-repeat rule can leave tickets unplayable in tiny pools.
                const size_t left = static_cast<size_t>(std::count(bag_.begin(), bag_.end(), i));
                refill_bag();
                fresh = true;
                const size_t per_deal = static_cast<size_t>(std::count(bag_.begin(), bag_.end(), i));
                const bool others = std::any_of(bag_.begin(), bag_.end(), [i](size_t t) { return t != i; });
                for (size_t n = others ? std::min(left, per_deal) : 0; n > 0; n--) {
                    std::uniform_int_distribution<size_t> at(0, bag_.size() - 1);
                    bag_.insert(bag_.begin() + static_cast<std::ptrdiff_t>(at(rng_)), i);
                }
                continue;
            }
        }
        bag_.pop_back();
        return i;
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
        auto it = by_id_.find(locked_file);
        refused_lock_ = it == by_id_.end() ? "unknown" : refusal(it->second);
        if (refused_lock_.empty()) {
            push_history(it->second);
            locked_ = true;
            return current();
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

bool PresetManager::in_history_walk(size_t index) const { return eligible(index) && !hidden(index); }

const PresetEntry* PresetManager::next() {
    if (has_current_) {
        for (size_t c = cursor_ + 1; c < history_.size(); c++) {
            if (in_history_walk(history_[c])) {
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
        if (in_history_walk(history_[c])) {
            cursor_ = c;
            return current();
        }
    }
    return nullptr;
}

const PresetEntry* PresetManager::find_playable(std::string_view id, std::string& reason) const {
    auto it = by_id_.find(id);
    reason = it == by_id_.end() ? "unknown" : refusal(it->second);
    return reason.empty() ? &entries_[it->second] : nullptr;
}

void PresetManager::played(const PresetEntry& entry, bool lock) {
    const size_t index = index_of(entry);
    if (index == NONE) return;
    push_history(index);
    locked_ = lock;
}

bool PresetManager::skip(const std::string& file) {
    skipped_.insert(file);
    const PresetEntry* cur = current();
    return cur != nullptr && cur->file == file;
}

bool PresetManager::set_high_frequency(bool include) {
    if (include == config_.high_frequency) return high_frequency_on_screen();
    config_.high_frequency = include;
    bag_.clear();  // re-deal with the new filter
    return high_frequency_on_screen();
}

bool PresetManager::excluded_high_frequency(size_t index) const {
    return index < entries_.size() && entries_[index].high_frequency && !config_.high_frequency;
}

// The id finds the entry; the address tells ours from a copy.
size_t PresetManager::index_of(const PresetEntry& entry) const {
    auto it = by_id_.find(entry.file);
    return it != by_id_.end() && &entries_[it->second] == &entry ? it->second : NONE;
}

void PresetManager::on_shown(const PresetEntry& entry, bool blend) {
    const size_t index = index_of(entry);
    if (index == NONE) return;  // not ours
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
