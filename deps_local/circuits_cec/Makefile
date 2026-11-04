# SPDX-FileCopyrightText: 2026 Ben Bangert
# SPDX-License-Identifier: Apache-2.0
#
# Builds the cec_port helper. Invoked by elixir_make.
#
# Targets:
#   all           build $(MIX_APP_PATH)/priv/cec_port
#   test-backend  build $(MIX_APP_PATH)/obj/cec_port_test (ioctls stubbed;
#                 used by the library's own tests, never shipped)
#   clean         remove build products
#
# Variables (set by elixir_make, and by Nerves when cross-compiling):
#   MIX_APP_PATH  build directory of this app under _build
#   CC            C compiler
#   CROSSCOMPILE  cross-compiler prefix, if any
#   CFLAGS        compiler flags
#   LDFLAGS       linker flags
#
# /dev/cecN is Linux-only. On any other host (with no CROSSCOMPILE) the
# targets are no-ops and Circuits.CEC reports {:error, :unsupported}.

ifeq ($(MIX_APP_PATH),)
$(error MIX_APP_PATH not set. Invoke via mix)
endif

PREFIX = $(MIX_APP_PATH)/priv
BUILD = $(MIX_APP_PATH)/obj

CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=c11 -D_GNU_SOURCE

SRC = c_src/cec_port.c
HEADERS = c_src/linux/cec.h
PORT = $(PREFIX)/cec_port
TEST_PORT = $(BUILD)/cec_port_test

BUILD_HELPER = 1
ifeq ($(CROSSCOMPILE),)
ifneq ($(shell uname -s),Linux)
BUILD_HELPER = 0
endif
endif

ifeq ($(BUILD_HELPER),1)

all: $(PORT)

test-backend: $(TEST_PORT)

$(PORT): $(SRC) $(HEADERS) Makefile | $(PREFIX)
	@echo " CC $(notdir $@)"
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDFLAGS)

$(TEST_PORT): $(SRC) c_src/test_backend.h $(HEADERS) Makefile | $(BUILD)
	@echo " CC $(notdir $@)"
	$(CC) $(CFLAGS) -DCEC_PORT_TEST_BACKEND -o $@ $(SRC) $(LDFLAGS)

$(PREFIX) $(BUILD):
	mkdir -p $@

else

all test-backend:
	@echo "circuits_cec: not a Linux build, skipping the cec_port helper"

endif

clean:
	$(RM) $(PORT) $(TEST_PORT)

.PHONY: all test-backend clean

# Don't echo commands unless the caller exports "V=1"
${V}.SILENT:
