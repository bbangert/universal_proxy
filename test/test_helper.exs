# `:hardware`-tagged tests need a real USB serial adapter on the
# host. Exclude them by default so CI (where no device is plugged
# in) reports them as `excluded`, not as failures. Devs running
# locally against a real adapter use `mix test --include hardware`.
#
# `:python3`-tagged tests shell out to a Python fixture standing in for
# `arecord`/system binaries. Excluding the tag only when python3 is
# actually missing keeps a normal run's coverage intact while turning a
# stripped host's failure mode from an opaque Port spawn error into a
# clean `excluded`.
python3_exclude = if System.find_executable("python3"), do: [], else: [:python3]

ExUnit.start(exclude: [:hardware] ++ python3_exclude)
