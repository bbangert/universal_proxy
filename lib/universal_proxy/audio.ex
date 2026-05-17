defmodule UniversalProxy.Audio do
  @moduledoc """
  Public API for the audio (Sendspin) subsystem.

  Thin boundary over `UniversalProxy.Audio.Server` and
  `UniversalProxy.Audio.Store`. The Server holds the live, merged view
  of enumerated outputs plus their persisted configuration; the Store
  owns the DETS table that survives reboots. Callers (LiveView,
  Phase 3's `Audio.Player`) should reach in via this module only.

  Outputs are identified by a `{slot_sub, vendor_id, product_id}`
  tuple. For built-in SoC cards on v1 hardware that's
  `{card_name, nil, nil}` (e.g. `{"bcm2835 Headphones", nil, nil}`).
  """

  alias UniversalProxy.Audio.{Server, Store}

  @typedoc """
  Composite identifier for an audio output:
  `{slot_sub, vendor_id, product_id}`.
  """
  @type key :: Store.output_key()

  @doc """
  List all currently-present audio outputs as merged maps (enumerate
  info + persisted config), sorted by `friendly_name`.
  """
  @spec list_outputs() :: [map()]
  def list_outputs, do: Server.list_outputs()

  @doc """
  Look up a single output. Returns `{:ok, merged_map}` if present,
  `:error` otherwise.
  """
  @spec get_output(key()) :: {:ok, map()} | :error
  def get_output({_, _, _} = key), do: Server.get_output(key)

  @doc """
  Update one or more configuration fields. Accepted keys:
  `:friendly_name`, `:volume`, `:muted`. Anything else is silently
  dropped. Returns `{:error, :not_found}` if the output isn't
  currently present, or `{:error, reason}` if DETS rejects the write.
  """
  @spec update_config(key(), map()) :: :ok | {:error, :not_found | term()}
  def update_config({_, _, _} = key, params) when is_map(params) do
    Server.update_config(key, params)
  end

  @doc """
  Enable or disable an output, persisted in DETS. Returns
  `{:error, :not_found}` if the output isn't currently present, or
  `{:error, reason}` if DETS rejects the write.
  """
  @spec set_enabled(key(), boolean()) :: :ok | {:error, :not_found | term()}
  def set_enabled({_, _, _} = key, enabled?) when is_boolean(enabled?) do
    Server.set_enabled(key, enabled?)
  end
end
