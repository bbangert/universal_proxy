defmodule UniversalProxy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start the Telemetry supervisor
        UniversalProxyWeb.Telemetry,
        # Start the PubSub system
        {Phoenix.PubSub, name: UniversalProxy.PubSub},
        # Start the Endpoint (http/https)
        UniversalProxyWeb.Endpoint,
        # Task supervisor for fire-and-forget work (e.g. async ESPHome restarts)
        {Task.Supervisor, name: UniversalProxy.TaskSupervisor},
        # SSH access key: generates the device's ed25519 keypair on first boot,
        # authorizes the public half for ssh login, and serves the private half
        # to the Security tab for download. No-op authorize on host.
        UniversalProxy.SSHAccess,
        # Ethernet-preferred Wi-Fi: suspends wlan0 (runtime-only) while any
        # Ethernet interface has connectivity, restores it when the cable is
        # pulled. No-op on host (VintageNet absent).
        UniversalProxy.WifiPolicy,
        # Start the UART subsystem (DynamicSupervisor + registry server)
        UniversalProxy.UART.Supervisor,
        # Audio (Sendspin) subsystem — enumerates ALSA outputs, persists
        # per-output config, broadcasts lifecycle events. Phase 1 holds
        # an empty PlayerSupervisor; Phase 3 adds player children.
        UniversalProxy.Audio.Supervisor,
        # FlooGoo FMA120 control channel (DETS prefs store + supervised
        # worker subtree). AFTER Audio.Supervisor so its hotplug events
        # (`sendspin:output_added`) flow. No-op when no FMA120 is attached
        # (empty inventory); works on host.
        UniversalProxy.FMA120.Store,
        UniversalProxy.FMA120.Supervisor,
        # ESPHome device identity store (DETS)
        UniversalProxy.ESPHome.ConfigStore,
        # ESPHome Noise PSK store (DETS). Sits beside ConfigStore at the
        # top level so a restart/0 of the ESPHome subtree never closes its
        # DETS file. Holds the HA-provisioned API encryption key.
        UniversalProxy.ESPHome.PskStore,
        # Firmware update flow (ConfigStore + library Supervisor, wired
        # together so the snapshot lands before the library starts).
        UniversalProxy.FirmwareUpdate,
        # Bluetooth subtree (registry, settings store, Bluez lifecycle).
        # BEFORE the ESPHome supervisor: its bluetooth_opts/0 reads the
        # persisted Bluetooth settings at espex boot. child_spec returns
        # `:ignore` outside BT-capable targets, so this is a no-op on host
        # (see UniversalProxy.Bluetooth @moduledoc).
        UniversalProxy.Bluetooth,
        # Espex-backed ESPHome Native API server with our hardware adapters
        UniversalProxy.ESPHome.Supervisor
      ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: UniversalProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UniversalProxyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
