defmodule UniversalProxy.TuyaBeaconMesh.Radio.Transport do
  @moduledoc """
  How `UniversalProxy.TuyaBeaconMesh.Radio` reaches its controller.

  The Radio owns everything that doesn't depend on how the controller is
  driven: the TX queue and classes, each frame's time on air (its own
  timers), `last_tx_sn`, duplicate and echo filtering, subscriber fan-out,
  setup retries and their backoff, the health-check timer and the
  wedge counting and escalation. A transport only does I/O on the Radio's
  behalf: bring the controller up and take it down, put one advert on
  air and take it off, run a health probe, and turn the messages its own
  resources send to the Radio into events.

  Every callback runs in the Radio process, so a transport may link,
  monitor and trap whatever it needs (the Radio traps exits) and receives
  those messages through `c:handle_info/2`. A transport never starts
  timers that decide when a frame comes off air or when setup is retried.

  ## Lifecycle

    * `c:init/1` — at Radio start, no I/O; gets the Radio's options with
      `:adapter_index` and `:adapter_address` (upper case, or `nil`)
      filled in.
    * `c:setup/2` — bring-up, on start and after every loss. With
      `reset?` true the controller is reset as part of it (after a wedge);
      a reset that ran is reported with a `{:controller_reset, how}`
      event, also when a later step failed (the Radio then doesn't ask
      for it again). On error the returned state still records what the
      attempt got, so `c:teardown/1` can undo exactly that.
    * `c:teardown/1` — undoes a (partial) setup before the Radio retries
      it; may keep what the next setup can reuse. The Radio has already
      taken any advert off air with `c:stop_transmit/2`.
    * `c:terminate/2` — releases everything when the Radio stops.

  ## Events

    * `{:report, address, frame, rssi}` — one 26-byte P2 frame heard
      (`address` the 48-bit advertiser address as an integer).
    * `{:lost, reason}` — the controller (or what reaches it) is gone; the
      Radio tears down and retries setup.
    * `{:fault, reason}` — the controller failed a command; counts towards
      declaring it wedged, like an advertise refused with `:fault`.
    * `{:controller_reset, how}` — the controller was reset (the only
      event `c:setup/2` returns; counted in `Radio.status/1`'s
      `:recoveries`).

  A transport holds no key material: frames reach it already encrypted
  (as advertising data) and leave it as raw 26-byte frames.
  """

  @type t :: term()
  @type reason :: term()
  @type instance :: term()

  @type event ::
          {:report, non_neg_integer(), binary(), integer()}
          | {:lost, reason()}
          | {:fault, reason()}
          | {:controller_reset, atom()}

  @typedoc """
  Why an advert didn't go on air: `:refused` (this frame only), `:fault`
  (the controller failed; counts towards a wedge) or `:uncertain` (the
  path to the controller went away mid-request, so the frame may have
  aired; the Radio re-runs setup).
  """
  @type transmit_error :: {:refused | :fault | :uncertain, reason()}

  @callback init(opts :: keyword()) :: {:ok, t()} | {:error, reason()}

  @typedoc "What `c:setup/2` may report besides its result."
  @type setup_event :: {:controller_reset, atom()}

  @callback setup(t(), reset? :: boolean()) ::
              {:ok, t(), [setup_event()]} | {:error, reason(), t(), [setup_event()]}

  @doc "Undoes setup (also a partial one) so that it can be retried."
  @callback teardown(t()) :: t()

  @callback terminate(reason :: term(), t()) :: :ok

  @doc """
  Puts `ad_bytes` (the advertising data) on air until `c:stop_transmit/2`.
  `instance` identifies it to `c:stop_transmit/2` and in `Radio.status/1`.
  """
  @callback transmit(t(), ad_bytes :: binary()) ::
              {:ok, instance(), t()} | {:error, transmit_error(), t()}

  @doc """
  Takes `instance` off air. An instance already gone (with the controller)
  is `:ok`; an error means its state can't be trusted, and the Radio
  re-runs setup.
  """
  @callback stop_transmit(t(), instance()) :: {:ok, t()} | {:error, reason(), t()}

  @doc """
  Probes, while ready, what can fail without any message reaching the
  Radio (scan ended behind its back, adapter replaced). An error makes the
  Radio re-run setup.
  """
  @callback health_check(t()) :: :ok | {:error, reason()}

  @callback handle_info(msg :: term(), t()) :: {:ok, [event()], t()} | :unhandled

  @doc "`:lease_held`, `:discovering` and `:listening` for `Radio.status/1`."
  @callback status(t()) :: %{
              lease_held: boolean(),
              discovering: boolean(),
              listening: boolean()
            }
end
