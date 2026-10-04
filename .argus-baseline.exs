# Reviewed argus findings: each is a validated false positive or deliberate
# design, with its reason. Checked by scripts/argus_baseline.exs (see its
# header for the workflow); prefer fixing a finding over adding it here.
[
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "UniversalProxy.ESPHome.EntityProvider registers with UniversalProxy.ESPHome.ConfigStore when it starts, and UniversalProxy.ESPHome.ConfigStore hands it to code outside the program, which may keep it. Both are children of the one_for_one supervisor UniversalProxy.Application, which restarts either alone. When UniversalProxy.ESPHome.ConfigStore restarts, its init/1 starts it afresh without what UniversalProxy.ESPHome.EntityProvider put there, and UniversalProxy.ESPHome.EntityProvider, which is not restarted with it, never registers again. When UniversalProxy.ESPHome.EntityProvider restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: ESPHome.ConfigStore.current/0 and device_config_opts/0 are reads of DETS-persisted config; ConfigStore keeps nothing about the caller and the 'handed on' call is Espex.DeviceConfig.detect_mac_address/0, a pure lookup. A ConfigStore restart loses no caller state."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "UniversalProxy.ESPHome.Supervisor registers with UniversalProxy.ESPHome.ConfigStore when it starts, and UniversalProxy.ESPHome.ConfigStore hands it to code outside the program, which may keep it. Both are children of the one_for_one supervisor UniversalProxy.Application, which restarts either alone. When UniversalProxy.ESPHome.ConfigStore restarts, its init/1 starts it afresh without what UniversalProxy.ESPHome.Supervisor put there, and UniversalProxy.ESPHome.Supervisor, which is not restarted with it, never registers again. When UniversalProxy.ESPHome.Supervisor restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: ESPHome.ConfigStore.current/0 and device_config_opts/0 are reads of DETS-persisted config; ConfigStore keeps nothing about the caller and the 'handed on' call is Espex.DeviceConfig.detect_mac_address/0, a pure lookup. A ConfigStore restart loses no caller state."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "UniversalProxy.Storage.Server registers with UniversalProxy.ESPHome.ConfigStore when it starts, and UniversalProxy.ESPHome.ConfigStore hands it to code outside the program, which may keep it. Both are children of the one_for_one supervisor UniversalProxy.Application, which restarts either alone. When UniversalProxy.ESPHome.ConfigStore restarts, its init/1 starts it afresh without what UniversalProxy.Storage.Server put there, and UniversalProxy.Storage.Server, which is not restarted with it, never registers again. When UniversalProxy.Storage.Server restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: ESPHome.ConfigStore.current/0 and device_config_opts/0 are reads of DETS-persisted config; ConfigStore keeps nothing about the caller and the 'handed on' call is Espex.DeviceConfig.detect_mac_address/0, a pure lookup. A ConfigStore restart loses no caller state."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "UniversalProxy.Storage.Server registers with UniversalProxy.Storage.Settings when it starts, and UniversalProxy.Storage.Settings keeps it in its state. Both are children of the one_for_one supervisor UniversalProxy.Application, which restarts either alone. When UniversalProxy.Storage.Settings restarts, its init/1 starts it afresh without what UniversalProxy.Storage.Server put there, and UniversalProxy.Storage.Server, which is not restarted with it, never registers again. When UniversalProxy.Storage.Server restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: Storage.Server only calls Storage.Settings' get/put API; Settings keeps no per-caller state (its data is the DETS table, which survives a Settings restart), so nothing needs re-registering."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/application.ex",
    title: "Coupled children under one_for_one",
    detail:
      "UniversalProxy.UART.History registers with UniversalProxy.ESPHome.ZWaveProxy when it starts, and UniversalProxy.ESPHome.ZWaveProxy keeps a monitor or link for it. Both are children of the one_for_one supervisor UniversalProxy.Application, which restarts either alone. When UniversalProxy.ESPHome.ZWaveProxy restarts, its init/1 starts it afresh without what UniversalProxy.UART.History put there, and UniversalProxy.UART.History, which is not restarted with it, never registers again. When UniversalProxy.UART.History restarts, it registers a second time beside what its old process left.",
    reason:
      "False positive: UART.History only queries ZWaveProxy.claimed_port/0 (a read; nothing is registered or monitored for History). The proxy's monitor at the flagged line is for its Espex subscriber, not History; after a proxy restart History learns the claim again from the uart:port_opened broadcast."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/input/capture.ex",
    title: "terminate/2 does unbounded work inside the shutdown timeout",
    detail:
      "UniversalProxy.Audio.Input.Capture.force_kill/1 calls :os.cmd/1 — a port or OS operation — from UniversalProxy.Audio.Input.Capture's terminate/2. The module traps exits, so the callback is reached, but a GenServer child gets only its shutdown timeout (5000ms unless the child spec says otherwise) before the supervisor brutal-kills it. A call with no bound of its own can exceed that, and the cleanup is truncated at whatever point it had reached — often worse than not starting.",
    reason:
      "Deliberate and bounded: terminate/2 closes the arecord port and, only if it is still open, sends `kill -9` to the integer OS pid via :os.cmd; both return promptly, well inside the 5s shutdown."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/input/server.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.Audio.Input.Server monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: the processes terminated here are orphans swept in init/1 from a previous incarnation; this incarnation never monitored them (it monitors only children it starts later)."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/input/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.Audio.Input.Server.init/1 reaches DynamicSupervisor.terminate_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.Audio.Input.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/input/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.Audio.Input.Server.init/1 reaches DynamicSupervisor.which_children on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.Audio.Input.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/audio/input/server.ex",
    title: "rest_for_one restarts the owner but not the processes it started",
    detail:
      "UniversalProxy.Audio.Input.Server (position 2) starts processes under DynamicSupervisor (position 0) of UniversalProxy.Audio.Input.Supervisor, a rest_for_one supervisor (inferred: the call's target is a runtime value and DynamicSupervisor is the only earlier DynamicSupervisor under UniversalProxy.Audio.Input.Supervisor). When UniversalProxy.Audio.Input.Server crashes, the supervisor restarts it and every later child, but DynamicSupervisor started earlier and survives — with the processes the old UniversalProxy.Audio.Input.Server started still running inside it. The new UniversalProxy.Audio.Input.Server knows nothing of them and starts its own: duplicated work, or a stale process holding a resource the replacement expects to own.",
    reason:
      "Deliberate: the server's init/1 sweeps every child a previous incarnation left under the earlier DynamicSupervisor (which_children + terminate_child) before starting its own, so no orphan survives a server restart."
  },
  %{
    analysis: "mailbox",
    file: "lib/universal_proxy/audio/input/source.ex",
    title: "A message the server is sent reaches only its catch-all handle_info/2",
    detail:
      "UniversalProxy.Audio.Input.Source.notify/2 sends {:source_event, …} to UniversalProxy.Audio.Input.Source, whose handle_info/2 is where it lands: no clause names it, and the catch-all that takes it does nothing with it but log it or ignore it.",
    reason:
      "False positive: notify/2 sends {:source_event, key, event} to state.owner (Audio.Input.Server, which handles it), not to the Source itself."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/input/source.ex",
    title: "Children started under another tree outlive their owner",
    detail:
      "UniversalProxy.Audio.Input.Source.stop_capture/1 starts children under UniversalProxy.TaskSupervisor, a DynamicSupervisor UniversalProxy.Audio.Input.Source does not sit under. Their lifetime follows UniversalProxy.TaskSupervisor's tree, not UniversalProxy.Audio.Input.Source's: when UniversalProxy.Audio.Input.Source's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and UniversalProxy.Audio.Input.Source's terminate/2 does not stop them.",
    reason:
      "Deliberate (CLAUDE.md idiom): fire-and-forget work goes through UniversalProxy.TaskSupervisor for crash visibility. The task is short and meant to complete even if the caller goes away: the task only stops the old arecord Capture (GenServer.stop, bounded at 2s, exits tolerated); the Capture is linked to the Source, so it dies with it anyway on a tree shutdown."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/input/source.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.Audio.Input.Source monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: the monitor at the flagged line is on the websocket (socket_monitor), demonitored with :flush in teardown_connection/2; the process terminated here is the linked Capture, which is not monitored."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/input/store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.Audio.Input.Store.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/player.ex",
    title: "terminate/2 does unbounded work inside the shutdown timeout",
    detail:
      "UniversalProxy.Audio.Player.send_raw/2 calls :erlang.port_command/2 — a port or OS operation — from UniversalProxy.Audio.Player's terminate/2. The module traps exits, so the callback is reached, but a GenServer child gets only its shutdown timeout (5000ms unless the child spec says otherwise) before the supervisor brutal-kills it. A call with no bound of its own can exceed that, and the cleanup is truncated at whatever point it had reached — often worse than not starting.",
    reason:
      "Deliberate and bounded: terminate/2 sends one JSON shutdown line, waits at most @shutdown_grace_ms (500ms) for exit_status, then Port.close and a `kill -9` backstop via :os.cmd; all well inside the 5s shutdown."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/audio/server.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.Audio.Server monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: the processes terminated here are orphans swept in init/1 from a previous incarnation; this incarnation never monitored them (it monitors only children it starts later)."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.Audio.Server.init/1 reaches DynamicSupervisor.terminate_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.Audio.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.Audio.Server.init/1 reaches DynamicSupervisor.which_children on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.Audio.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/audio/server.ex",
    title: "rest_for_one restarts the owner but not the processes it started",
    detail:
      "UniversalProxy.Audio.Server (position 3) starts processes under DynamicSupervisor (position 0) of UniversalProxy.Audio.Supervisor, a rest_for_one supervisor (inferred: the call's target is a runtime value and DynamicSupervisor is the only earlier DynamicSupervisor under UniversalProxy.Audio.Supervisor). When UniversalProxy.Audio.Server crashes, the supervisor restarts it and every later child, but DynamicSupervisor started earlier and survives — with the processes the old UniversalProxy.Audio.Server started still running inside it. The new UniversalProxy.Audio.Server knows nothing of them and starts its own: duplicated work, or a stale process holding a resource the replacement expects to own.",
    reason:
      "Deliberate: the server's init/1 sweeps every child a previous incarnation left under the earlier DynamicSupervisor (which_children + terminate_child) before starting its own, so no orphan survives a server restart."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/audio/store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.Audio.Store.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/bluetooth.ex",
    title: "Children started under another tree outlive their owner",
    detail:
      "UniversalProxy.Bluetooth.restart_esphome/0 starts children under UniversalProxy.TaskSupervisor, a DynamicSupervisor UniversalProxyWeb.BluetoothLive does not sit under. Their lifetime follows UniversalProxy.TaskSupervisor's tree, not UniversalProxyWeb.BluetoothLive's: when UniversalProxyWeb.BluetoothLive's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and UniversalProxyWeb.BluetoothLive's terminate/2 does not stop them.",
    reason:
      "Deliberate (CLAUDE.md idiom): fire-and-forget work goes through UniversalProxy.TaskSupervisor for crash visibility. The task is short and meant to complete even if the caller goes away: restarting the ESPHome supervisor after a settings change must still happen if the caller (a LiveView or the Bluetooth manager) exits."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/bluetooth/manager.ex",
    title: "Children started under another tree outlive their owner",
    detail:
      "UniversalProxy.Bluetooth.Manager.restart_esphome/0 starts children under UniversalProxy.TaskSupervisor, a DynamicSupervisor UniversalProxy.Bluetooth.Manager does not sit under. Their lifetime follows UniversalProxy.TaskSupervisor's tree, not UniversalProxy.Bluetooth.Manager's: when UniversalProxy.Bluetooth.Manager's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and UniversalProxy.Bluetooth.Manager's terminate/2 does not stop them.",
    reason:
      "Deliberate (CLAUDE.md idiom): fire-and-forget work goes through UniversalProxy.TaskSupervisor for crash visibility. The task is short and meant to complete even if the caller goes away: restarting the ESPHome supervisor after a settings change must still happen if the caller (a LiveView or the Bluetooth manager) exits."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/bluetooth/manager.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.Bluetooth.Manager.init/1 reaches Task.Supervisor.start_child on UniversalProxy.TaskSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.Bluetooth.Manager, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "False positive: init/1 only stores &restart_esphome/0 in state (esphome_restart_fun); it is first invoked from handle_continue(:reconcile) and only on a paused-state change, never during init."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/bluetooth/settings.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.Bluetooth.Settings.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/btd700/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.BTD700.Server.init/1 reaches DynamicSupervisor.start_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.BTD700.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/btd700/store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.BTD700.Store.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/esphome.ex",
    title: "Children started under another tree outlive their owner",
    detail:
      "UniversalProxy.ESPHome.update_config/1 starts children under UniversalProxy.TaskSupervisor, a DynamicSupervisor UniversalProxyWeb.DiscoveryLive does not sit under. Their lifetime follows UniversalProxy.TaskSupervisor's tree, not UniversalProxyWeb.DiscoveryLive's: when UniversalProxyWeb.DiscoveryLive's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and UniversalProxyWeb.DiscoveryLive's terminate/2 does not stop them.",
    reason:
      "Deliberate (CLAUDE.md idiom): fire-and-forget work goes through UniversalProxy.TaskSupervisor for crash visibility. The task is short and meant to complete even if the caller goes away: restarting the ESPHome supervisor after a settings change must still happen if the caller (a LiveView or the Bluetooth manager) exits."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/esphome/config_store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.ESPHome.ConfigStore.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/esphome/infrared/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.ESPHome.Infrared.Server.init/1 reaches DynamicSupervisor.start_child on UniversalProxy.ESPHome.Infrared.WorkerSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.ESPHome.Infrared.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/esphome/psk_store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.ESPHome.PskStore.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/firmware_update/config_store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.FirmwareUpdate.ConfigStore.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/fma120/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.FMA120.Server.init/1 reaches DynamicSupervisor.start_child on a supervisor chosen at runtime. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.FMA120.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/fma120/store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.FMA120.Store.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/ssh_access.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.SSHAccess.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/storage/server.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.Storage.Server monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: stop_share/1 calls demonitor_share/1 (Process.demonitor(ref, [:flush])) before terminate_share_child/1 and the sweep; argus does not follow the helper."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/storage/server.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.Storage.Server monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: stop_share/1 calls demonitor_share/1 (Process.demonitor(ref, [:flush])) before terminate_share_child/1 and the sweep; argus does not follow the helper."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/storage/settings.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.Storage.Settings.init/1 performs close during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/storage/settings.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.Storage.Settings.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/uart/history.ex",
    title: "handle_continue races a later sibling",
    detail:
      "UniversalProxy.UART.History sync-calls UniversalProxy.ESPHome.ZWaveProxy, a later sibling, from handle_continue under UniversalProxy.Application. The continue runs concurrently with the supervisor's start sequence, so whether UniversalProxy.ESPHome.ZWaveProxy is alive when the call lands is a boot-time race — it works on the fast machine and fails in CI.",
    reason:
      "Deliberate: History's boot-time ZWaveProxy.claimed_port/0 call is wrapped in catch :exit (returns nil when the proxy is not up yet); the proxy's uart:port_opened lifecycle broadcast (owner: :zwave_proxy) adds the claim when it opens the port."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy/uart/server.ex",
    title: "Server terminates a process it still monitors",
    detail:
      "UniversalProxy.UART.Server monitors processes from its callbacks and also terminates them on purpose, without demonitoring first. The {:DOWN, ...} for a death this server caused is delivered like any other — into the clause written for crashes, which may restart, reconnect or log what was a deliberate stop.",
    reason:
      "False positive: the processes terminated here are orphans swept in init/1 from a previous incarnation; this incarnation never monitored them (it monitors only children it starts later)."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/uart/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.UART.Server.init/1 reaches DynamicSupervisor.terminate_child on UniversalProxy.UART.PortSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.UART.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/uart/server.ex",
    title: "init/1 makes a synchronous supervisor call",
    detail:
      "UniversalProxy.UART.Server.init/1 reaches DynamicSupervisor.which_children on UniversalProxy.UART.PortSupervisor. Every supervisor management call is a GenServer.call into the supervisor; start_child in particular does not return until the new child's init/1 has, so those inits now run inside this one, on the tree's startup path. A child that calls back into UniversalProxy.UART.Server, or into anything not yet started, deadlocks the boot; terminate_child waits for the whole shutdown of the child.",
    reason:
      "Deliberate: init/1 sweeps orphans left by a previous incarnation under an earlier sibling DynamicSupervisor (already running under rest_for_one); terminating them before serving is the point, and they never call back into this server."
  },
  %{
    analysis: "coupling",
    file: "lib/universal_proxy/uart/server.ex",
    title: "rest_for_one restarts the owner but not the processes it started",
    detail:
      "UniversalProxy.UART.Server (position 2) starts processes under DynamicSupervisor (position 0) of UniversalProxy.UART.Supervisor, a rest_for_one supervisor. When UniversalProxy.UART.Server crashes, the supervisor restarts it and every later child, but DynamicSupervisor started earlier and survives — with the processes the old UniversalProxy.UART.Server started still running inside it. The new UniversalProxy.UART.Server knows nothing of them and starts its own: duplicated work, or a stale process holding a resource the replacement expects to own.",
    reason:
      "Deliberate: the server's init/1 sweeps every child a previous incarnation left under the earlier DynamicSupervisor (which_children + terminate_child) before starting its own, so no orphan survives a server restart."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/uart/settings_store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.UART.SettingsStore.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "startup",
    file: "lib/universal_proxy/uart/store.ex",
    title: "Distributed operation in init/1",
    detail:
      "UniversalProxy.UART.Store.init/1 performs open_file during init, while the supervisor's start sequence waits. A slow or partitioned peer stalls local startup.",
    reason:
      "False positive: argus classes every :dets call as a distributed (Mnesia-style) store operation, but this is a local DETS file on the device's data partition. Opening it in init/1 is deliberate so a store that cannot open fails its start instead of serving without a table."
  },
  %{
    analysis: "shutdown",
    file: "lib/universal_proxy_web/live/overview_live.ex",
    title: "Children started under another tree outlive their owner",
    detail:
      "UniversalProxyWeb.OverviewLive.start_format/3 starts children under UniversalProxy.TaskSupervisor, a DynamicSupervisor UniversalProxyWeb.OverviewLive does not sit under. Their lifetime follows UniversalProxy.TaskSupervisor's tree, not UniversalProxyWeb.OverviewLive's: when UniversalProxyWeb.OverviewLive's tree shuts down they keep running — reconnecting, logging, calling into applications that have already stopped — and UniversalProxyWeb.OverviewLive's terminate/2 does not stop them.",
    reason:
      "Deliberate (CLAUDE.md idiom): fire-and-forget work goes through UniversalProxy.TaskSupervisor for crash visibility. The task is short and meant to complete even if the caller goes away: a drive format started from the Overview must run to completion even if the LiveView (browser tab) goes away; Storage.Server serializes it and reports progress over PubSub."
  }
]
