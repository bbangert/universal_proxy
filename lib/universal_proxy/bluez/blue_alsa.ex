defmodule UniversalProxy.Bluez.BlueAlsa do
  @moduledoc """
  Persistent `rebus` D-Bus client to `org.bluealsa` (the bluez-alsa
  `bluealsad` daemon), used to learn which A2DP-playback PCMs are *ready to
  open* right now. This is the control-plane half of the Bluetooth-headphone
  audio path; the data plane is sendspin opening the ALSA PCM string directly.

  `pcms/0` returns, for every connected A2DP headset, the information
  `UniversalProxy.Bluetooth.AudioSink` needs to surface it as a Sendspin
  output:

      %{
        mac: "AA:BB:CC:DD:EE:FF",
        pcm_path: "/org/bluealsa/hci0/dev_.../a2dpsrc/sink",
        alsa_string: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
        alias: "WH-1000XM4"   # org.bluez Device1.Alias, falls back to the MAC
      }

  ## Connection, not the daemon

  This client connects to the **system bus** (owned by `dbus-daemon`, the first
  child of `UniversalProxy.Bluez`), not to `bluealsad`. So it comes up whether
  or not `bluealsad` has claimed `org.bluealsa` yet; `GetPCMs` simply errors
  (→ `[]`) until the daemon is up, and starts returning PCMs once a headset
  connects. It survives a `bluealsad` restart without reconnecting.

  ## Inert off-target / when not started

  The `UniversalProxy.Bluez` subtree only runs on the BT targets, so on
  host/CI this GenServer isn't started. `pcms/0` catches the `:exit` from
  calling a non-existent process and returns `[]`, mirroring the exit-safe
  pattern used elsewhere in the Bluez layer — callers stay inert.

  Enrichment with the device `Alias` is a best-effort `org.bluez`
  `Properties.Get` on the same connection (BlueAlsa already proves D-Bus is
  reachable); a failed Alias lookup falls back to the MAC, never raises.
  """

  use GenServer
  require Logger

  alias UniversalProxy.Bluez.{DBus, Variant}

  @bluealsa "org.bluealsa"
  @manager_path "/org/bluealsa"
  @manager_iface "org.bluealsa.Manager1"
  @bluez_device_iface "org.bluez.Device1"
  @props_iface "org.freedesktop.DBus.Properties"

  # GetPCMs is a local round-trip; keep a tight budget because Audio.Server
  # calls pcms/0 synchronously inside its 5 s refresh and must not stall if
  # bluealsad wedges.
  @call_timeout 2_000

  # Device path tail: `.../dev_AA_BB_CC_DD_EE_FF` (under any hciX). We pull the
  # MAC from the org.bluealsa PCM's Device path rather than the (adapter-scoped)
  # DevicePath helper so it works regardless of which adapter owns the headset.
  @dev_mac_re ~r"/dev_([0-9A-Fa-f_]{17})$"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Connected A2DP-playback PCMs as a list of maps (see the moduledoc). `[]` when
  the daemon is down, no headset is connected, or this client isn't running.
  """
  @spec pcms() :: [
          %{mac: String.t(), pcm_path: String.t(), alsa_string: String.t(), alias: String.t()}
        ]
  def pcms do
    GenServer.call(__MODULE__, :pcms, @call_timeout + 1_000)
  catch
    :exit, _ -> []
  end

  @impl GenServer
  def init(_opts) do
    case Rebus.connect(:system) do
      {:ok, conn} ->
        conn_ref = Process.monitor(conn)
        {:ok, %{conn: conn, conn_ref: conn_ref}}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:pcms, _from, state) do
    {:reply, list_pcms(state.conn), state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    # The bus connection died (e.g. a malformed frame stopped it). Stop so the
    # Bluez supervisor restarts us with a fresh connection.
    {:stop, {:dbus_connection_down, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- internals --

  defp list_pcms(conn) do
    case DBus.call_to(
           conn,
           @bluealsa,
           @manager_path,
           @manager_iface,
           "GetPCMs",
           "",
           [],
           @call_timeout
         ) do
      {:ok, [pcm_array]} when is_list(pcm_array) ->
        pcm_array
        |> Enum.flat_map(&playback_pcm(&1, conn))

      {:ok, other} ->
        Logger.warning("BlueAlsa GetPCMs unexpected reply: #{inspect(other)}")
        []

      {:error, _reason} ->
        # bluealsad not up yet / no org.bluealsa owner — inert until it is.
        []
    end
  end

  # Each entry is `{pcm_path, props_list}` (a{oa{sv}}). Keep only A2DP PCMs the
  # daemon is *sending* to a headset: Transport ~ "A2DP" and Mode == "sink"
  # (the client writes into a sink PCM; that audio is encoded out to the BT
  # device). HFP/SCO and the capture (source) direction are dropped.
  defp playback_pcm({pcm_path, props_list}, conn) when is_binary(pcm_path) do
    props = Variant.unwrap_props(props_list)
    transport = props["Transport"] || ""
    mode = props["Mode"]
    device_path = props["Device"]

    with true <- is_binary(device_path),
         true <- String.contains?(transport, "A2DP"),
         "sink" <- mode,
         {:ok, mac} <- mac_from_device_path(device_path) do
      [
        %{
          mac: mac,
          pcm_path: pcm_path,
          alsa_string: "bluealsa:DEV=#{mac},PROFILE=a2dp",
          alias: device_alias(conn, device_path, mac)
        }
      ]
    else
      _ -> []
    end
  end

  defp playback_pcm(_other, _conn), do: []

  defp mac_from_device_path(path) do
    case Regex.run(@dev_mac_re, path) do
      [_, dev] -> {:ok, dev |> String.replace("_", ":") |> String.upcase()}
      _ -> :error
    end
  end

  # Best-effort org.bluez Device1.Alias for a friendly card name; MAC on any
  # failure so a card always has a usable name.
  defp device_alias(conn, device_path, mac) do
    # Properties.Get returns a single variant `{signature, value}`.
    case DBus.call(
           conn,
           device_path,
           @props_iface,
           "Get",
           "ss",
           [@bluez_device_iface, "Alias"],
           @call_timeout
         ) do
      {:ok, [{_sig, name}]} when is_binary(name) and name != "" -> name
      _ -> mac
    end
  end
end
