# Universal Proxy — project conventions

## Testing / builds

- Run tests with `mise run test` (bare `MIX_TARGET=host mix test` is
  silently overridden by mise's shell hook).
- Dialyzer is a host-only CI gate, not part of the test alias:
  `mise exec -- sh -c 'MIX_TARGET=host MIX_ENV=dev mix dialyzer'`.
- Build firmware with `mise run firmware -- <target>`.

## Public-API `catch :exit` idiom (deliberate tradeoff)

Optional-subsystem public APIs (Bluetooth, FMA120, firmware update,
Z-Wave, …) wrap their `GenServer.call`s in `catch :exit, _ ->
<default>` so callers work on any target and while a subsystem is down.

Be aware what this swallows: `catch :exit` converts BOTH the
process-not-running exit AND a call **timeout** into the same
"subsystem off" default — a wedged server renders as a disabled
subsystem rather than raising. This is a deliberate tradeoff (benign
UI degradation over crash cascades), accepted in the 2026-07 OTP
audit (F8). New wrappers must follow the same idiom knowingly; if a
wedged-vs-off distinction matters for a new API, catch only
`:exit, {:timeout, _}` separately (see `UniversalProxy.FMA120`'s
`call_worker/2` for the pattern).

## Process design conventions

- Fire-and-forget work goes through `Task.Supervisor.start_child(
  UniversalProxy.TaskSupervisor, fun)`, never bare `Task.start` (crash
  visibility).
- Never call `Circuits.UART.drain/1` — `tcdrain(3)` blocks indefinitely
  if CTS is de-asserted; use `flush(:receive)` only.
- `Registry.register/dispatch/unregister` raise `ArgumentError` when
  the registry isn't started — defensive adapters rescue that, not
  `catch :exit`.
