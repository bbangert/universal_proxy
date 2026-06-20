defmodule UniversalProxy.ESPHome.Clients do
  @moduledoc """
  Connected ESPHome native-API clients — the data behind the header
  "connected clients" pill.

  Implements `Espex.ConnectionListener`: espex calls `connections_changed/0`
  (fire-and-forget, no payload) whenever a client connects or disconnects,
  and we re-broadcast a hint on `UniversalProxy.PubSub` so the LiveViews
  re-read the live set. Per espex's guidance the callback is only a hint —
  `list/0` (backed by `Espex.connected_clients/0`) is the source of truth,
  so consumers also read it on mount to reconcile anything missed at boot.

  `list/0` maps each `Espex.ClientInfo` to a render-ready view model
  (display name/version parsed from the client's `HelloRequest` info,
  human "connected since" / "last packet" durations, encryption state).
  """

  @behaviour Espex.ConnectionListener

  require Logger

  alias Phoenix.PubSub

  @topic "esphome:clients"

  @doc "PubSub topic broadcast when the connected-client set changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl Espex.ConnectionListener
  def connections_changed do
    # espex invokes this in a detached, error-catching task, so a direct
    # (fast, non-blocking) PubSub broadcast is safe here — no intermediary
    # process needed. Consumers refetch via list/0 (the source of truth).
    PubSub.broadcast(UniversalProxy.PubSub, @topic, :esphome_clients_changed)
  end

  @doc """
  The currently-connected native-API clients as render-ready view models,
  Home-Assistant clients first then oldest-connection first. Tolerates espex
  being momentarily down (returns `[]`).
  """
  @spec list() :: [map()]
  def list do
    build(safe_connected_clients(), System.system_time(:second), uptime_seconds())
  end

  @doc """
  Pure mapping of `Espex.ClientInfo` structs to sorted view models, relative
  to `now` (epoch seconds). Split out from `list/0` so it's testable without
  live connections.

  `cap` (device uptime in seconds, or `nil`) bounds the reported durations: a
  live connection cannot be older than the current boot, so clamping to uptime
  hides bogus ages from the Nerves boot-time clock step (the RTC starts stale
  and NTP steps it forward *after* a client has already connected, leaving a
  pre-step `connected_at` decades off).
  """
  @spec build([Espex.ClientInfo.t()], integer(), non_neg_integer() | nil) :: [map()]
  def build(clients, now, cap \\ nil) when is_list(clients) do
    clients
    |> Enum.map(&to_view(&1, now, cap))
    |> Enum.sort_by(&{!&1.home_assistant?, &1.connected_at_raw})
  end

  # -- Private --

  # Defensive: espex's connection registry is briefly absent while the ESPHome
  # subtree restarts (e.g. an API-encryption Reset), and `Registry` *raises*
  # ArgumentError — it does not exit — when the registry isn't started. Guard
  # both so the header pill renders empty instead of crashing the LiveView.
  defp safe_connected_clients do
    Espex.connected_clients()
  rescue
    ArgumentError -> []
  catch
    :exit, _ -> []
  end

  # Whole-second device uptime, or nil off Linux / on read failure (no clamp).
  defp uptime_seconds do
    with {:ok, contents} <- File.read("/proc/uptime"),
         [secs | _] <- String.split(contents),
         {f, _} <- Float.parse(secs) do
      trunc(f)
    else
      other ->
        Logger.debug(
          "ESPHome clients: no /proc/uptime cap (#{inspect(other)}); durations uncapped"
        )

        nil
    end
  end

  defp to_view(%Espex.ClientInfo{} = c, now, cap) do
    {name, kind, version} = parse_client_info(c.client_info)

    %{
      id: "client-" <> Integer.to_string(:erlang.phash2(c.id)),
      name: name,
      kind: kind,
      version: version,
      home_assistant?: kind == "Home Assistant",
      peer: c.peer,
      encrypted?: c.encrypted?,
      connected_at_raw: c.connected_at || now,
      since: format_duration(c.connected_at, now, cap),
      last_seen: format_ago(c.last_activity_at, now, cap)
    }
  end

  # The ESPHome HelloRequest client_info is a free-form string, conventionally
  # "<client name> <version>" (e.g. "Home Assistant 2026.1.0"). Pull a trailing
  # version token off the end and classify the remainder.
  defp parse_client_info(nil), do: {"Native API client", "Native API client", nil}
  defp parse_client_info(""), do: {"Native API client", "Native API client", nil}

  defp parse_client_info(info) when is_binary(info) do
    # client_info is conventionally "<name> <version>" so take the LAST
    # version-like token, not the first.
    version =
      case Regex.scan(~r/\b\d+\.\d+(?:\.\d+)?\S*/, info) do
        [] -> nil
        matches -> matches |> List.last() |> hd()
      end

    name =
      info
      |> then(fn s -> if version, do: String.replace(s, version, ""), else: s end)
      |> String.trim()
      |> case do
        "" -> info
        trimmed -> trimmed
      end

    {name, classify(name), version}
  end

  defp classify(name) do
    cond do
      name =~ ~r/home\s*assistant/i -> "Home Assistant"
      name =~ ~r/esphome/i -> "ESPHome"
      true -> "Native API client"
    end
  end

  # "connected since" — coarse, largest-then-next unit (e.g. "3d 14h", "8m 41s").
  defp format_duration(nil, _now, _cap), do: "—"

  defp format_duration(at, now, cap) do
    secs = elapsed(at, now, cap)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m #{rem(secs, 60)}s"
      secs < 86_400 -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      true -> "#{div(secs, 86_400)}d #{rem(div(secs, 3600), 24)}h"
    end
  end

  # "last packet" — single coarse unit, with a "just now" floor.
  defp format_ago(nil, _now, _cap), do: "—"

  defp format_ago(at, now, cap) do
    secs = elapsed(at, now, cap)

    cond do
      secs < 3 -> "just now"
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  # Non-negative elapsed seconds, capped at device uptime when known — a live
  # connection can't predate the current boot, so this absorbs clock steps.
  defp elapsed(at, now, nil), do: max(now - at, 0)
  defp elapsed(at, now, cap), do: (now - at) |> max(0) |> min(cap)
end
