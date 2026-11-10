defmodule UniversalProxy.Audio.Input do
  @moduledoc """
  Public API for the audio **input** (Sendspin `source@v1`) subsystem.

  The mirror of `UniversalProxy.Audio` for capture cards: a thin boundary
  over `UniversalProxy.Audio.Input.Server`, which holds the live merged view
  of enumerated capture cards plus their persisted configuration and derived
  connection state. Callers (LiveView, diagnostics) reach in through this
  module only — never through the Server, the Store, or a `Source` directly.

  Inputs are identified by the same `{slot_sub, vendor_id, product_id}` tuple
  as outputs: `{usb_port || card_name, vid, pid}`.

  ## Degradation

  Unlike `UniversalProxy.Audio`, every function here wraps its call in
  `catch :exit` and answers with a safe default. The input subtree is
  optional in practice — a host build, a target with no capture card, or a
  subtree that is mid-restart must not crash a LiveView mount. Per
  `CLAUDE.md`, be aware this also converts a *call timeout* into the same
  default: a wedged Server renders as "no inputs" rather than raising. That
  is the accepted house tradeoff (benign UI degradation over crash
  cascades).
  """

  alias UniversalProxy.Audio.Input.{Server, Store}

  @typedoc """
  Composite identifier for a capture input:
  `{slot_sub, vendor_id, product_id}`.
  """
  @type key :: Store.input_key()

  @doc """
  List all currently-present capture inputs as merged maps (enumerate info +
  persisted config + derived live state), sorted by `friendly_name`. Returns
  `[]` when the input subtree isn't running.
  """
  @spec list_inputs() :: [map()]
  def list_inputs do
    Server.list_inputs()
  catch
    :exit, _ -> []
  end

  @doc """
  Look up a single input. Returns `{:ok, merged_map}` if present, `:error`
  otherwise — including when the input subtree isn't running.
  """
  @spec get_input(key()) :: {:ok, map()} | :error
  def get_input({_, _, _} = key) do
    Server.get_input(key)
  catch
    :exit, _ -> :error
  end

  @doc """
  Force a synchronous hotplug re-enumeration. Returns `:ok` even when the
  input subtree isn't running — there is nothing to converge in that case.
  """
  @spec check_now() :: :ok
  def check_now do
    Server.check_now()
  catch
    :exit, _ -> :ok
  end

  @doc """
  Open the local "allow pairing" consent window for one input. This is the
  operator gesture the `source@v1` client requires before it will answer a
  peer's pairing offer with `client/pair-init` (an unrequested pairing offer is
  otherwise refused). Returns `:ok` even when the input subtree isn't running.
  """
  @spec allow_pairing(key()) :: :ok
  def allow_pairing({_, _, _} = key) do
    Server.allow_pairing(key)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Read an input's Sendspin pairing token (the `"SP:0…"` string a server such
  as Music Assistant takes to pair with it over the Pairing PSK method),
  minting its pairing PSK on first use.

  Built on every call from the persisted identity and never cached or
  broadcast: it is a long-lived pairing secret. `{:error, :unavailable}` when
  the input isn't present, the subsystem is down, or the store can't answer.
  """
  @spec pairing_token(key()) :: {:ok, String.t()} | {:error, :unavailable}
  def pairing_token({_, _, _} = key) do
    Server.pairing_token(key)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Unpair an input from one server (`server_id`) or from every server
  (`:all`): the pairing record goes, and a live session it keyed is closed so
  the server sees the change and can re-pair. `{:error, :unavailable}` when
  the input isn't present or the subsystem is down.
  """
  @spec unpair(key(), String.t() | :all) :: :ok | {:error, :unavailable}
  def unpair({_, _, _} = key, which) when is_binary(which) or which == :all do
    Server.unpair(key, which)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Replace an input's pairing PSK, so its old pairing token no longer pairs.
  Existing pairing records keep working. `{:error, :unavailable}` when the
  input isn't present or the subsystem is down.
  """
  @spec regenerate_pairing_token(key()) :: :ok | {:error, :unavailable}
  def regenerate_pairing_token({_, _, _} = key) do
    Server.regenerate_pairing_token(key)
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
