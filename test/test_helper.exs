# `:hardware`-tagged tests need a real USB serial adapter on the
# host. Exclude them by default so CI (where no device is plugged
# in) reports them as `excluded`, not as failures. Devs running
# locally against a real adapter use `mix test --include hardware`.
ExUnit.start(exclude: [:hardware])
