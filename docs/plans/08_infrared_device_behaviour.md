# Infrared Device Behaviour

## Problem

`Infrared.Server` interacts with product modules through three implicit contracts, none of which are formally defined:

**1. Identification (duck-typed on module):**

```215:219:lib/universal_proxy/esphome/infrared/server.ex
  defp find_product_module(info) do
    case Enum.find(@product_modules, fn mod -> mod.match?(info) end) do
      nil -> :error
      mod -> {:ok, mod}
    end
```

```186:186:lib/universal_proxy/esphome/infrared/server.ex
            entity = mod.build_entity(config, path, info)
```

**2. Worker startup (Server knows the child spec shape):**

```222:228:lib/universal_proxy/esphome/infrared/server.ex
  defp start_worker(entity) do
    child_spec = {
      entity.worker_module,
      entity: entity, server_pid: self()
    }
    DynamicSupervisor.start_child(@worker_supervisor, child_spec)
  end
```

**3. Transmit (Server bypasses DeviceWorker's public API):**

```86:88:lib/universal_proxy/esphome/infrared/server.ex
            GenServer.call(worker_pid, {:transmit, timings, opts}, 12_000)
```

`DeviceWorker` already exposes a clean `transmit/3` function, but the Server reaches through it and hardcodes the GenServer message format and timeout. A future product family with a different internal protocol, timeout, or process model would require changing the Server.

The receive direction has the same issue -- workers send `{:infrared_receive, key, timings}` to `server_pid` by convention, but nothing documents or enforces this.

## Change

### 1. New behaviour: `lib/universal_proxy/esphome/infrared/device.ex`

Define `UniversalProxy.ESPHome.Infrared.Device` with four callbacks covering the full boundary between the generic infrastructure and product-specific implementations:

```elixir
defmodule UniversalProxy.ESPHome.Infrared.Device do
  alias UniversalProxy.ESPHome.Infrared.Entity

  @doc "Returns true if the USB enumeration info matches this product family."
  @callback match?(info :: map()) :: boolean()

  @doc "Build an Entity from a saved UART config, port path, and enumeration info."
  @callback build_entity(config :: map(), port_path :: String.t(), info :: map()) :: Entity.t()

  @doc """
  Return a child spec for starting a worker process under the DynamicSupervisor.

  The worker must send `{:infrared_receive, key, timings}` to `server_pid`
  when IR signals are received (timings as signed microsecond integers,
  positive = mark, negative = space).
  """
  @callback child_spec(entity :: Entity.t(), server_pid :: pid()) :: Supervisor.child_spec()

  @doc """
  Transmit ESPHome-native IR timings through a running worker process.

  Timings are signed microsecond integers (positive = mark, negative = space).
  The implementation handles all translation to the device-specific wire protocol.

  Options: `:carrier_frequency` (Hz, default 38000), `:repeat_count` (default 1).
  """
  @callback transmit(worker :: pid(), timings :: [integer()], opts :: keyword()) ::
              :ok | {:error, term()}
end
```

The receive contract is documented in `child_spec/2`'s doc -- workers send `{:infrared_receive, key, timings}` to `server_pid`. This is a message protocol (not a function call) so it can't be a callback, but it is part of the formal contract.

### 2. Adopt the behaviour in `Irdroid.Device`

In [lib/universal_proxy/esphome/infrared/irdroid/device.ex](lib/universal_proxy/esphome/infrared/irdroid/device.ex):

- Add `@behaviour UniversalProxy.ESPHome.Infrared.Device`
- Add `@impl true` to existing `match?/1` and `build_entity/3`
- Change `build_entity/3` to set `device_module: __MODULE__` instead of `worker_module: DeviceWorker`
- Add `child_spec/2` that returns the spec for `DeviceWorker`:

```elixir
@impl true
def child_spec(entity, server_pid) do
  %{
    id: entity.key,
    start: {DeviceWorker, :start_link, [[entity: entity, server_pid: server_pid]]},
    restart: :temporary
  }
end
```

- Add `transmit/3` delegating to the worker's existing public API:

```elixir
@impl true
defdelegate transmit(worker, timings, opts), to: DeviceWorker
```

### 3. Rename `worker_module` to `device_module` in Entity

In [lib/universal_proxy/esphome/infrared/entity.ex](lib/universal_proxy/esphome/infrared/entity.ex), rename the field from `worker_module` to `device_module` in the struct, typespec, and `new/1`. This reflects that the field now points to the behaviour implementor (the product module), not the internal worker GenServer.

### 4. Update `Infrared.Server` to use the behaviour

In [lib/universal_proxy/esphome/infrared/server.ex](lib/universal_proxy/esphome/infrared/server.ex):

**`start_worker/1`** -- use the behaviour's `child_spec/2` instead of hardcoding the tuple format:

```elixir
defp start_worker(entity) do
  spec = entity.device_module.child_spec(entity, self())
  DynamicSupervisor.start_child(@worker_supervisor, spec)
end
```

**`transmit_raw` handler** -- call through the behaviour instead of raw GenServer.call:

```elixir
def handle_call({:transmit_raw, key, timings, opts}, _from, state) do
  case Map.fetch(state.workers, key) do
    {:ok, {device_module, worker_pid}} ->
      result =
        try do
          device_module.transmit(worker_pid, timings, opts)
        catch
          :exit, reason -> {:error, {:worker_exit, reason}}
        end
      {:reply, result, state}

    :error ->
      {:reply, {:error, :unknown_device}, state}
  end
end
```

This requires the `workers` map to store `%{key => {device_module, worker_pid}}` instead of `%{key => worker_pid}`, so the Server can dispatch transmit through the correct behaviour module. Update `build_inventory/0` accordingly.

### 5. Update tests

In [test/universal_proxy/esphome/infrared/entity_test.exs](test/universal_proxy/esphome/infrared/entity_test.exs), update any references from `worker_module` to `device_module`.
