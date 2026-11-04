defmodule UniversalProxy.Bluetooth.HeldRadios do
  @moduledoc """
  Radios this app has taken away from `bluetoothd`: today the Tuya mesh
  Radio holding its adapter over the HCI user channel
  (`UniversalProxy.TuyaBeaconMesh.Radio.Transport.UserChannel`).

  While a user channel is bound the kernel removes the index from MGMT, so
  `bluetoothd` and `Bluez.Client` no longer list it: the adapter would read
  as an unidentified hciN (sysfs still has it) and its MAC as missing. A
  holder records here which MAC it holds and under which index, and the
  Bluetooth layer (`RadioMonitor`, `Manager`, `UniversalProxy.Bluetooth`)
  reads that instead of concluding the radio is gone.

  A `:unique` `Registry` keyed by MAC (`"AA:BB:CC:DD:EE:FF"`). The entry
  belongs to the process that called `hold/3`, so it goes away with that
  process, crash included, and `list/1` skips holders that are no longer
  alive (the Registry drops their entries a moment later). `hold/3` and
  `release/2` broadcast `{:bluetooth_held_changed}` on `topic/0` so readers
  re-read without polling; an exit sends nothing, so readers that care
  monitor the holder pids `list/1` returns.

  Started by the `UniversalProxy.Bluetooth` supervisor (BT targets only).
  Without it every function is a no-op: `hold/3` and `release/2` return
  `:ok`, `list/1` returns `[]` (`Registry` raises `ArgumentError` when the
  registry isn't running, rescued here).

  Options on every function: `:registry` (default `#{inspect(__MODULE__)}`)
  and `:pubsub` (default `UniversalProxy.PubSub`), for tests.
  """

  @registry __MODULE__
  @topic "bluetooth:held"
  @stale_retries 10
  @stale_retry_ms 10

  @type holder :: :tuya_mesh

  @type entry :: %{
          address: String.t(),
          index: non_neg_integer(),
          holder: holder(),
          pid: pid()
        }

  @doc "The registry's child spec."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    Supervisor.child_spec(
      {Registry, keys: :unique, name: Keyword.get(opts, :registry, @registry)},
      id: __MODULE__
    )
  end

  @doc "PubSub topic of `{:bluetooth_held_changed}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Records that the calling process holds `mac` under hci`index` for
  `holder` (default `:tuya_mesh`). Holding it again updates the entry.
  `{:error, :held_elsewhere}` when another live process holds it. An entry
  left by a holder that just exited is waited out (the Registry drops it
  a moment after the exit), for up to #{@stale_retries * @stale_retry_ms} ms.
  """
  @spec hold(String.t(), non_neg_integer(), keyword()) :: :ok | {:error, :held_elsewhere}
  def hold(mac, index, opts \\ []) when is_binary(mac) and is_integer(index) do
    value = %{index: index, holder: Keyword.get(opts, :holder, :tuya_mesh)}
    register(registry(opts), String.upcase(mac), value, opts, @stale_retries)
  rescue
    ArgumentError -> :ok
  end

  defp register(registry, key, value, opts, retries) do
    case Registry.register(registry, key, value) do
      {:ok, _owner} ->
        notify(opts)

      {:error, {:already_registered, pid}} when pid == self() ->
        {_new, _old} = Registry.update_value(registry, key, fn _old -> value end)
        notify(opts)

      {:error, {:already_registered, pid}} ->
        if retries > 0 and not Process.alive?(pid) do
          Process.sleep(@stale_retry_ms)
          register(registry, key, value, opts, retries - 1)
        else
          {:error, :held_elsewhere}
        end
    end
  end

  @doc "Drops the calling process's hold on `mac`, if it has one."
  @spec release(String.t(), keyword()) :: :ok
  def release(mac, opts \\ []) when is_binary(mac) do
    registry = registry(opts)
    key = String.upcase(mac)
    me = self()

    case Registry.lookup(registry, key) do
      [{^me, _value}] ->
        :ok = Registry.unregister(registry, key)
        notify(opts)

      _none_or_other ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Every radio held by a live process, sorted by index."
  @spec list(keyword()) :: [entry()]
  def list(opts \\ []) do
    opts
    |> registry()
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {_mac, pid, _value} -> Process.alive?(pid) end)
    |> Enum.map(fn {mac, pid, value} -> Map.merge(value, %{address: mac, pid: pid}) end)
    |> Enum.sort_by(& &1.index)
  rescue
    ArgumentError -> []
  end

  @doc "Whether a live process holds `mac`."
  @spec held?(String.t(), keyword()) :: boolean()
  def held?(mac, opts \\ []) when is_binary(mac) do
    case Registry.lookup(registry(opts), String.upcase(mac)) do
      [{pid, _value}] -> Process.alive?(pid)
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  defp registry(opts), do: Keyword.get(opts, :registry, @registry)

  # Registry-backed PubSub raises ArgumentError when it isn't running.
  defp notify(opts) do
    _ =
      Phoenix.PubSub.broadcast(
        Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
        @topic,
        {:bluetooth_held_changed}
      )

    :ok
  rescue
    ArgumentError -> :ok
  end
end
