// Minimal one-shot SHA-256 (FIPS 180-4) for naming artwork files by content.
//
// Licensed under the Apache License, Version 2.0.

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

// Lowercase hex digest of `len` bytes at `data`.
std::string sha256_hex(const uint8_t* data, size_t len);
