defmodule UniversalProxy.Cec.Ctl do
  @moduledoc """
  Runs `cec-ctl` (from v4l-utils) one-shots and builds its argument lists.

  The kernel keeps the claimed logical address as adapter state, so a single
  `--playback` claim at startup is enough and every later command is an
  independent short-lived process. Replies to a request (`--give-device-
  power-status`, `--give-audio-status`) are waited for by cec-ctl itself and
  come back in its stdout, which `UniversalProxy.Cec.Parser` decodes.

  A behaviour so tests swap in a recording fake via the
  `UniversalProxy.Cec` application env (`:ctl_module`).
  """

  @callback run([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}

  @behaviour __MODULE__

  @default_timeout_ms 5_000

  # CEC user-control (remote key) codes, CEC 1.4 table 27.
  @ui_cmd %{volume_up: 0x41, volume_down: 0x42, mute: 0x43, power_on: 0x6D, power_off: 0x6C}

  @doc "Name (or path) of the cec-ctl binary; overridable via `:ctl_binary`."
  @spec binary() :: String.t()
  def binary, do: Keyword.get(config(), :ctl_binary, "cec-ctl")

  @doc "True when cec-ctl is on the PATH of this image."
  @spec available?() :: boolean()
  def available?, do: System.find_executable(binary()) != nil

  @impl true
  def run(args, opts \\ []) when is_list(args) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    case System.find_executable(binary()) do
      nil ->
        {:error, :cec_ctl_missing}

      path ->
        case MuonTrap.cmd(path, args, timeout: timeout, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, :timeout} -> {:error, {:timeout, out}}
          {out, status} -> {:error, {:exit, status, out}}
        end
    end
  end

  # ── argument builders ─────────────────────────────────────────────────
  #
  # `-s` skips the Driver Info dump every one-shot would otherwise print.
  # Broadcast messages (`--active-source`) take no `--to`; cec-ctl refuses a
  # directed message without one.

  @spec claim_playback_args(String.t(), String.t()) :: [String.t()]
  def claim_playback_args(dev, osd_name),
    do: ["-d", dev, "-s", "--playback", "--osd-name", osd_name]

  @doc "No message: prints the Driver Info block (physical + logical address)."
  @spec driver_info_args(String.t()) :: [String.t()]
  def driver_info_args(dev), do: ["-d", dev]

  @spec monitor_args(String.t()) :: [String.t()]
  def monitor_args(dev), do: ["-d", dev, "-s", "-m"]

  @spec image_view_on_args(String.t()) :: [String.t()]
  def image_view_on_args(dev), do: ["-d", dev, "-s", "--to", "0", "--image-view-on"]

  @spec active_source_args(String.t(), String.t()) :: [String.t()]
  def active_source_args(dev, phys_addr),
    do: ["-d", dev, "-s", "--active-source", "phys-addr=#{phys_addr}"]

  @spec standby_args(String.t(), 0..15) :: [String.t()]
  def standby_args(dev, la), do: ["-d", dev, "-s", "--to", Integer.to_string(la), "--standby"]

  @spec give_power_status_args(String.t(), 0..15) :: [String.t()]
  def give_power_status_args(dev, la),
    do: ["-d", dev, "-s", "--to", Integer.to_string(la), "--give-device-power-status"]

  @spec give_audio_status_args(String.t(), 0..15) :: [String.t()]
  def give_audio_status_args(dev, la),
    do: ["-d", dev, "-s", "--to", Integer.to_string(la), "--give-audio-status"]

  @doc "Press-and-release of one remote key, sent as two messages in one invocation."
  @spec user_control_args(String.t(), 0..15, atom()) :: [String.t()]
  def user_control_args(dev, la, key) when is_map_key(@ui_cmd, key) do
    code = Map.fetch!(@ui_cmd, key)

    [
      "-d",
      dev,
      "-s",
      "--to",
      Integer.to_string(la),
      "--user-control-pressed",
      "ui-cmd=0x" <> Integer.to_string(code, 16),
      "--user-control-released"
    ]
  end

  defp config, do: Application.get_env(:universal_proxy, UniversalProxy.Cec, [])
end
