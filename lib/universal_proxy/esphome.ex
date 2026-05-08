defmodule UniversalProxy.ESPHome do
  @moduledoc """
  Public API for the ESPHome Native API subsystem.

  The wire protocol, framing, encryption, and connection lifecycle are
  provided by the [`espex`](https://hexdocs.pm/espex) library. This module
  is a thin façade for reading and updating the device identity used at
  start-up time.

  ## Examples

      # View current device identity
      UniversalProxy.ESPHome.config()

      # Update the device name (persisted; takes effect after a restart)
      UniversalProxy.ESPHome.update_config(name: "my-proxy", friendly_name: "My Proxy")

      # Get the listening port
      UniversalProxy.ESPHome.port()

  """

  require Logger

  alias UniversalProxy.ESPHome.{ConfigStore, Supervisor}

  @doc """
  Returns the merged device configuration (defaults + persisted overrides).
  """
  @spec config() :: map()
  def config, do: ConfigStore.current()

  @doc """
  Persist the given keyword list of device configuration overrides and
  restart the ESPHome supervisor so the changes take effect.

  Returns `{:ok, config}` on success or `{:error, reason}` if the
  underlying DETS write fails. The supervisor restart is only scheduled
  when persistence succeeds.
  """
  @spec update_config(keyword()) :: {:ok, map()} | {:error, term()}
  def update_config(opts) when is_list(opts) do
    case ConfigStore.put(opts) do
      :ok ->
        Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
          case Supervisor.restart() do
            {:ok, _pid} -> :ok
            {:error, reason} -> Logger.error("ESPHome restart failed: #{inspect(reason)}")
          end
        end)

        {:ok, ConfigStore.current()}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Returns the TCP port the ESPHome API is configured to listen on.
  """
  @spec port() :: non_neg_integer()
  def port, do: Map.fetch!(config(), :port)
end
