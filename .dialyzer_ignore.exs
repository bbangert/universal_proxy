# Dialyzer warnings to suppress.
#
# Each entry is either a regex matched against the formatted warning,
# or a `{file, type}` / `{file, type, line}` tuple. See
# https://hexdocs.pm/dialyxir/readme.html#ignore-warnings.
#
# On `MIX_TARGET=host` (CI), `VintageNet` is genuinely not loaded — the
# library is provided by `:nerves_pack`, which `mix.exs` restricts to
# Nerves targets. Calls in `UniversalProxy.System` are gated by
# `Code.ensure_loaded?(VintageNet)` at runtime, so the
# `unknown_function` warnings dialyzer emits on host are spurious.
# On Nerves targets the warnings don't fire, so we skip the entry there
# (avoids "Unnecessary Skips" noise).

case Mix.target() do
  :host ->
    [
      {"lib/universal_proxy/system.ex", :unknown_function}
    ]

  _ ->
    []
end
