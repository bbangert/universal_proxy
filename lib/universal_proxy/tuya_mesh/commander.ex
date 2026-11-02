defmodule UniversalProxy.TuyaMesh.Commander do
  @moduledoc """
  Runs Home Assistant light commands on the Tuya mesh: maps each one to DP
  batches (`UniversalProxy.TuyaMesh.Commands`) and sends them through
  `UniversalProxy.TuyaBeaconMesh.Lights`, off the `EntityProvider`'s loop
  (`command/2` is a cast).

  One process serialises every command. Its Lights calls are inline (Lights
  is one process too, so nothing is lost), and every wait is a timer, so a
  newer command is always handled before the next step of an older one.

  ## Sends

  Every batch is an acked set (`ack: true`): the ack draws a DP report,
  the only read-back the bulbs have.

    * **Bulb:** the batches go out in order with `Lights.set/3`.
    * **Group:** the batches go out with `Lights.group_set/3`. A group
      frame reaches only part of the members (4–9 of 10 on hardware), so
      after `:window_ms` every member that hasn't reported the DPs since the
      command (its `last_report_ms` moved and its DPs match) gets one
      round of direct sets carrying only what it is missing, one every
      `:followup_gap_ms` and at most `:max_followups` frames per command.

  `{:error, :busy}` and `{:error, :queue_full}` are retried after
  `:retry_ms`, doubling, at most `:max_retries` times; any other error
  stops the command (a follow-up error skips that bulb).

  ## Superseding

  A newer command for a light replaces the older one's remaining batches,
  retries and follow-ups, so slider drags don't queue up (the Radio
  already coalesces queued frames for the same light and DPs). A group
  command also replaces its members' bulb commands, and no follow-up goes
  to a bulb that got a newer command of its own after the group's.

  ## Optimistic state

  Each light's last known DPs are kept here: what was sent to it, over
  the Lights report DPs for a bulb first commanded. Once a command's sends
  are accepted, the light's `LightStateResponse` (with its `device_id`) is
  pushed to Espex, so HA doesn't snap back. A light whose on/off isn't
  known yet gets no push. A refused send pushes nothing.

  Options: `:name`, `:lights` (module, default `Lights`) and `:lights_opts`
  (extra options to its calls, e.g. `server:`), `:members` (`gid ->
  {:ok, [mac]} | :error`, default from `UniversalProxy.TuyaMesh.status/1`),
  `:push` (`struct -> any`, default `Espex.push_state/2` on `:server`),
  `:server`, `:window_ms` (6 s), `:retry_ms` (500 ms), `:max_retries` (5),
  `:followup_gap_ms` (2 s), `:max_followups` (10).
  """

  # TODO(4c): reconcile `views` with real reports (Lights report updates,
  # group aggregation) and push member bulb states after a group command.

  use GenServer

  require Logger

  alias Espex.Proto
  alias UniversalProxy.TuyaBeaconMesh.Lights
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.Commands

  @retryable [:busy, :queue_full]

  @type target :: {:bulb, String.t()} | {:group, 0..254}
  @type command :: %{
          target: target(),
          key: non_neg_integer(),
          device_id: non_neg_integer(),
          settings: Commands.settings(),
          request: Proto.LightCommandRequest.t()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Queues a light command. Never blocks; a no-op when not running."
  @spec command(command(), GenServer.server()) :: :ok
  def command(command, server \\ __MODULE__), do: GenServer.cast(server, {:command, command})

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    server = Keyword.get(opts, :server, Espex.Server)

    {:ok,
     %{
       lights: Keyword.get(opts, :lights, Lights),
       lights_opts: Keyword.get(opts, :lights_opts, []),
       members: Keyword.get(opts, :members, &default_members/1),
       push: Keyword.get(opts, :push, &default_push(server, &1)),
       window_ms: Keyword.get(opts, :window_ms, 6_000),
       retry_ms: Keyword.get(opts, :retry_ms, 500),
       max_retries: Keyword.get(opts, :max_retries, 5),
       followup_gap_ms: Keyword.get(opts, :followup_gap_ms, 2_000),
       max_followups: Keyword.get(opts, :max_followups, 10),
       next_id: 1,
       jobs: %{},
       views: %{},
       touched: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:command, %{target: target, request: request} = command}, state) do
    base = base_dps(state, target)
    current = Map.get(state.views, target, base)

    case Commands.batches(request, command.settings, current) do
      [] ->
        Logger.debug("TuyaMesh.Commander: nothing to send for #{inspect(target)}")
        {:noreply, state}

      batches ->
        {:noreply, start_job(state, command, base, batches)}
    end
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:step, target, id}, state) do
    case Map.get(state.jobs, target) do
      %{id: ^id} = job -> {:noreply, step(state, job)}
      _superseded -> {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Jobs ─────────────────────────────────────────────────────────────

  defp start_job(state, command, base, batches) do
    id = state.next_id
    target = command.target
    members = members(state, target)

    job = %{
      id: id,
      target: target,
      command: command,
      base: base,
      phase: :send,
      pending: batches,
      sent: [],
      attempts: 0,
      members: members,
      snapshot: snapshot(state, target, members)
    }

    macs = if match?({:bulb, _}, target), do: [elem(target, 1)], else: members

    # A group command replaces its members' own commands.
    jobs = Map.drop(state.jobs, for(mac <- members, do: {:bulb, mac}))
    touched = Map.merge(state.touched, Map.new(macs, &{&1, id}))

    send(self(), {:step, target, id})

    %{
      state
      | next_id: id + 1,
        jobs: Map.put(jobs, target, job),
        touched: touched
    }
  end

  defp step(state, %{phase: :send, pending: [batch | rest]} = job) do
    case send_batch(state, job.target, batch) do
      :ok ->
        state = record(state, job, batch)
        job = %{job | pending: rest, sent: job.sent ++ batch, attempts: 0}
        if rest == [], do: sent_all(state, job), else: continue(state, job, 0)

      {:error, reason} when reason in @retryable ->
        retry(state, job, reason, fn state -> stop_sending(state, job) end)

      {:error, reason} ->
        Logger.info(
          "TuyaMesh.Commander: #{describe(job.target)} command failed: #{inspect(reason)}"
        )

        stop_sending(state, job)
    end
  end

  defp step(state, %{phase: :check} = job), do: check(state, job)

  defp step(state, %{phase: :followup, pending: []} = job), do: done(state, job)

  defp step(state, %{phase: :followup, pending: [{mac, batch} | rest]} = job) do
    if newer_command?(state, mac, job) do
      step(state, %{job | pending: rest, attempts: 0})
    else
      followup(state, job, mac, batch, rest)
    end
  end

  defp followup(state, job, mac, batch, rest) do
    case state.lights.set(mac, batch, [ack: true] ++ state.lights_opts) do
      :ok ->
        continue(state, %{job | pending: rest, attempts: 0}, state.followup_gap_ms)

      {:error, reason} when reason in @retryable ->
        retry(state, job, reason, fn state ->
          step(state, %{job | pending: rest, attempts: 0})
        end)

      {:error, reason} ->
        Logger.info("TuyaMesh.Commander: follow-up to #{mac} failed: #{inspect(reason)}")
        step(state, %{job | pending: rest, attempts: 0})
    end
  end

  defp send_batch(state, {:bulb, mac}, batch),
    do: state.lights.set(mac, batch, [ack: true] ++ state.lights_opts)

  defp send_batch(state, {:group, gid}, batch),
    do: state.lights.group_set(gid, batch, [ack: true] ++ state.lights_opts)

  defp retry(state, job, reason, give_up) do
    if job.attempts < state.max_retries do
      delay = state.retry_ms * Integer.pow(2, job.attempts)
      continue(state, %{job | attempts: job.attempts + 1}, delay)
    else
      Logger.info(
        "TuyaMesh.Commander: #{describe(job.target)} still #{inspect(reason)} " <>
          "after #{job.attempts} retries; giving up"
      )

      give_up.(state)
    end
  end

  # What went out still counts: pushed, but no follow-ups for the rest.
  defp stop_sending(state, %{sent: []} = job), do: done(state, job)
  defp stop_sending(state, job), do: done(push(state, job), job)

  defp sent_all(state, %{target: {:bulb, _}} = job), do: done(push(state, job), job)

  defp sent_all(state, %{members: []} = job), do: done(push(state, job), job)

  defp sent_all(state, job),
    do: continue(push(state, job), %{job | phase: :check, pending: []}, state.window_ms)

  # Members that haven't shown the DPs since the command get them directly.
  defp check(state, job) do
    case state.lights.all(state.lights_opts) do
      {:ok, bulbs} ->
        by_mac = Map.new(bulbs, &{&1.mac, &1})

        {followups, dropped} =
          job.members
          |> Enum.reject(&newer_command?(state, &1, job))
          |> Enum.flat_map(&followups_for(&1, Map.get(by_mac, &1), job))
          |> Enum.split(state.max_followups)

        if dropped != [] do
          Logger.debug(
            "TuyaMesh.Commander: #{describe(job.target)}: #{length(dropped)} follow-ups over the cap"
          )
        end

        step(state, %{job | phase: :followup, pending: followups, attempts: 0})

      {:error, reason} ->
        Logger.debug("TuyaMesh.Commander: no follow-ups (Lights: #{inspect(reason)})")
        done(state, job)
    end
  end

  defp followups_for(mac, bulb, job) do
    missing =
      if reported_since?(bulb, Map.get(job.snapshot, mac)),
        do: Commands.unconfirmed(job.sent, Map.get(bulb, :dps, %{})),
        else: job.sent

    for batch <- Commands.split(missing), do: {mac, batch}
  end

  defp reported_since?(%{last_report_ms: at}, before) when is_integer(at), do: at != before
  defp reported_since?(_bulb, _before), do: false

  defp newer_command?(state, mac, job), do: Map.get(state.touched, mac, 0) > job.id

  defp continue(state, job, delay) do
    if delay == 0,
      do: send(self(), {:step, job.target, job.id}),
      else: Process.send_after(self(), {:step, job.target, job.id}, delay)

    %{state | jobs: Map.put(state.jobs, job.target, job)}
  end

  defp done(state, job) do
    case Map.get(state.jobs, job.target) do
      %{id: id} when id == job.id -> %{state | jobs: Map.delete(state.jobs, job.target)}
      _other -> state
    end
  end

  # ── Views and optimistic state ───────────────────────────────────────

  # What a sent batch set, kept for the light (and for members already
  # known, after a group batch).
  defp record(state, job, batch) do
    sent = Commands.expected(batch)
    views = Map.update(state.views, job.target, Map.merge(job.base, sent), &Map.merge(&1, sent))

    views =
      Enum.reduce(job.members, views, fn mac, views ->
        case Map.fetch(views, {:bulb, mac}) do
          {:ok, view} -> Map.put(views, {:bulb, mac}, Map.merge(view, sent))
          :error -> views
        end
      end)

    %{state | views: views}
  end

  defp push(state, job) do
    %{key: key, device_id: device_id, settings: settings} = job.command

    case Commands.state_response(Map.get(state.views, job.target, %{}), settings, key, device_id) do
      nil -> :ok
      response -> state.push.(response)
    end

    state
  end

  defp default_push(server, struct) do
    Espex.push_state(server, struct)
  rescue
    ArgumentError -> :ok
  end

  # ── Inputs ───────────────────────────────────────────────────────────

  # A bulb first commanded starts from the DPs it last reported.
  defp base_dps(%{views: views} = state, {:bulb, mac} = target)
       when not is_map_key(views, target) do
    case state.lights.status(mac, state.lights_opts) do
      {:ok, %{dps: dps}} when is_map(dps) -> dps
      _other -> %{}
    end
  end

  defp base_dps(_state, _target), do: %{}

  defp members(_state, {:bulb, _mac}), do: []

  defp members(state, {:group, gid}) do
    case state.members.(gid) do
      {:ok, macs} when is_list(macs) -> macs
      _unknown -> []
    end
  end

  defp snapshot(_state, _target, []), do: %{}

  defp snapshot(state, _target, members) do
    case state.lights.all(state.lights_opts) do
      {:ok, bulbs} ->
        for %{mac: mac} = bulb <- bulbs,
            mac in members,
            into: %{},
            do: {mac, Map.get(bulb, :last_report_ms)}

      _error ->
        %{}
    end
  end

  defp default_members(gid) do
    case Enum.find(TuyaMesh.status().groups, &(&1.local_id == gid)) do
      %{members: macs} -> {:ok, macs}
      nil -> :error
    end
  end

  defp describe({:bulb, mac}), do: "bulb #{mac}"
  defp describe({:group, gid}), do: "group #{gid}"
end
