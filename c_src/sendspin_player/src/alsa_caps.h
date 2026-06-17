#pragma once

#include <cstdint>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// ALSA capability probe
// ---------------------------------------------------------------------------
//
// Probes a hardware ALSA device for the playback sample rates and sample
// formats it actually accepts, so the player can advertise hi-res formats
// (24-bit / >48 kHz) only when the attached DAC supports them.
//
// Empirical (snd_pcm_hw_params_test_*) rather than parsed from
// /proc/asound: UAC2 USB DACs report *continuous* rate ranges that the
// kernel mishandles, so a real test-open against the configuration space is
// the only authoritative source. See plan/scratchpad for #64.
//
// This is a distinct concern from `AlsaPipeSink` (long-lived playback open);
// the probe is a transient open/close that runs once at startup.

/// Result of probing a hardware device. On failure (`ok == false`) the
/// vectors are empty and the caller falls back to the baseline format floor.
struct ProbedCaps {
    std::vector<uint32_t> rates;      ///< accepted sample rates (Hz)
    std::vector<uint8_t> bit_depths;  ///< accepted bit depths (16 / 24 / 32)
    bool ok = false;                  ///< false ⇒ use baseline floor
};

/// Probe `hw_device` (e.g. "hw:0,0") with a transient `snd_pcm_open`.
///
/// Any failure — open error, EBUSY, EINVAL, an empty result set, or an
/// empty device string — yields `{.ok = false}` with empty vectors. Never
/// throws and never aborts: the probe must not be able to take the player
/// down. The PCM handle is always closed before returning, so the playback
/// path can later open `plughw:` without device contention.
ProbedCaps probe_caps(const std::string& hw_device);

/// Derive the device to probe from a `--alsa-device` value by swapping a
/// leading "plughw:" for "hw:" (e.g. "plughw:1,0" → "hw:1,0"). A value that
/// is already "hw:..." is returned unchanged. Anything else — "default",
/// the empty string, or a non-card device — returns "" so the caller skips
/// probing and uses the baseline floor.
std::string hw_device_for_probe(const std::string& alsa_device);
