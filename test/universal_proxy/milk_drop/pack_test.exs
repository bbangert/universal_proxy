defmodule UniversalProxy.MilkDrop.PackTest do
  # async: false — the Req.Test stub is shared (the download runs in a
  # TaskSupervisor child of the unnamed Pack server) and the PubSub topic
  # is global.
  use ExUnit.Case, async: false

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.Pack

  @moduletag :tmp_dir
  @stub __MODULE__
  @version "2026.11.1"
  @url "https://example.test/up-milkdrop-pack-2026.11.1.tar.gz"

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "milkdrop")
    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, MilkDrop.pack_topic())
    {:ok, root: root, src: Path.join(tmp_dir, "src")}
  end

  defp tarball(src, entries) do
    File.mkdir_p!(src)
    path = Path.join(src, "pack-#{System.unique_integer([:positive])}.tar.gz")
    entries = Enum.map(entries, fn {name, content} -> {to_charlist(name), content} end)
    :ok = :erl_tar.create(to_charlist(path), entries, [:compressed])
    File.read!(path)
  end

  defp good_pack(src) do
    tarball(src, [
      {"manifest.json", ~s({"presets":[]})},
      {"presets/a.milk", String.duplicate("a", 5_000)},
      {"shaders/0001.glsl", "void main() {}"}
    ])
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp pin(body, overrides \\ %{}),
    do: Map.merge(%{version: @version, url: @url, sha256: sha256(body)}, overrides)

  defp start_pack(root, pin) do
    tasks = start_supervised!(Task.Supervisor)

    start_supervised!(
      {Pack,
       name: nil,
       root: root,
       pin: pin,
       task_supervisor: tasks,
       req_options: [plug: {Req.Test, @stub}]}
    )
  end

  # Serves `body`, honouring `Range: bytes=N-` with a 206.
  defp serve(body, test_pid \\ self()) do
    Req.Test.stub(@stub, fn conn ->
      range = Plug.Conn.get_req_header(conn, "range")
      send(test_pid, {:request, range})
      size = byte_size(body)

      case range do
        ["bytes=" <> spec] ->
          {start, "-"} = Integer.parse(spec)

          conn
          |> Plug.Conn.put_resp_header("content-range", "bytes #{start}-#{size - 1}/#{size}")
          |> Plug.Conn.send_resp(206, binary_part(body, start, size - start))

        [] ->
          conn
          |> Plug.Conn.put_resp_header("content-length", Integer.to_string(size))
          |> Plug.Conn.send_resp(200, body)
      end
    end)
  end

  defp await_final do
    receive do
      {:milkdrop_pack, {:downloading, _}} -> await_final()
      {:milkdrop_pack, status} -> status
    after
      5_000 -> flunk("no final pack status")
    end
  end

  test "downloads, verifies and extracts the pinned pack", %{root: root, src: src} do
    body = good_pack(src)
    serve(body)
    server = start_pack(root, pin(body))

    assert Pack.status(server) == :absent
    assert {:downloading, 0} = Pack.ensure(server)
    assert_receive {:milkdrop_pack, {:downloading, 0}}

    dir = Path.join(root, @version)
    assert await_final() == {:ready, @version, dir}
    assert Pack.status(server) == {:ready, @version, dir}

    assert File.read!(Path.join(dir, "manifest.json")) == ~s({"presets":[]})
    assert File.read!(Path.join(dir, "presets/a.milk")) == String.duplicate("a", 5_000)
    refute File.exists?(Path.join(root, @version <> ".tar.gz.part"))
    refute File.exists?(Path.join(root, @version <> ".tmp"))
    assert_received {:request, []}

    # Idempotent once ready: no second request.
    assert Pack.ensure(server) == {:ready, @version, dir}
    refute_received {:request, _}
  end

  test "reports progress up to 100%", %{root: root, src: src} do
    body = good_pack(src)
    serve(body)
    server = start_pack(root, pin(body))

    Pack.ensure(server)
    assert_receive {:milkdrop_pack, {:downloading, 100}}, 5_000
    assert {:ready, @version, _} = await_final()
  end

  test "ensure/1 while downloading does not start a second download", %{root: root, src: src} do
    body = good_pack(src)
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:request, self()})

      receive do
        :go -> Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    server = start_pack(root, pin(body))
    assert {:downloading, 0} = Pack.ensure(server)
    assert_receive {:request, handler}
    assert {:downloading, 0} = Pack.ensure(server)

    send(handler, :go)
    assert {:ready, @version, _} = await_final()
    refute_received {:request, _}
  end

  test "detects an already-extracted pack on start", %{root: root} do
    dir = Path.join(root, @version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), "{}")

    server = start_pack(root, pin("irrelevant"))
    assert Pack.status(server) == {:ready, @version, dir}
    # No stub: a request would fail the download.
    assert Pack.ensure(server) == {:ready, @version, dir}
  end

  test "a version dir without a manifest is not ready", %{root: root} do
    File.mkdir_p!(Path.join(root, @version))
    server = start_pack(root, pin("irrelevant"))
    assert Pack.status(server) == :absent
  end

  test "no pin: ensure/1 reports :no_pack_pinned", %{root: root} do
    server = start_pack(root, nil)
    assert Pack.status(server) == :absent
    assert Pack.ensure(server) == {:error, :no_pack_pinned}
    assert Pack.status(server) == {:error, :no_pack_pinned}
    assert_receive {:milkdrop_pack, {:error, :no_pack_pinned}}
  end

  test "an unsafe version in the pin is refused", %{root: root} do
    server = start_pack(root, pin("x", %{version: "../escape"}))
    assert Pack.ensure(server) == {:error, :invalid_pin}
  end

  test "the configured pin is a well-formed release asset of its version" do
    assert %{version: version, url: url, sha256: sha256} = Pack.configured_pin()
    assert version =~ ~r/\A[0-9A-Za-z][0-9A-Za-z._-]*\z/
    assert sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert url ==
             "https://github.com/bbangert/up-milkdrop-pack/releases/download/" <>
               "#{version}/up-milkdrop-pack-#{version}.tar.gz"
  end

  @tag capture_log: true
  test "a checksum mismatch deletes the .part", %{root: root, src: src} do
    body = good_pack(src)
    serve(body)
    server = start_pack(root, pin(body, %{sha256: String.duplicate("0", 64)}))

    Pack.ensure(server)
    assert await_final() == {:error, :checksum_mismatch}
    refute File.exists?(Path.join(root, @version <> ".tar.gz.part"))
    refute File.exists?(Path.join(root, @version))
  end

  test "resumes an existing .part with a Range request", %{root: root, src: src} do
    body = good_pack(src)
    split = div(byte_size(body), 2)
    File.mkdir_p!(root)
    File.write!(Path.join(root, @version <> ".tar.gz.part"), binary_part(body, 0, split))

    serve(body)
    server = start_pack(root, pin(body))
    Pack.ensure(server)

    assert {:ready, @version, _} = await_final()
    assert_received {:request, ["bytes=" <> range]}
    assert range == "#{split}-"
  end

  test "restarts from zero when the server ignores Range", %{root: root, src: src} do
    body = good_pack(src)
    File.mkdir_p!(root)
    File.write!(Path.join(root, @version <> ".tar.gz.part"), "stale bytes that are not the pack")

    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
    server = start_pack(root, pin(body))
    Pack.ensure(server)

    assert {:ready, @version, _} = await_final()
  end

  @tag capture_log: true
  test "an HTTP error status is reported and nothing is written", %{root: root} do
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end)
    server = start_pack(root, pin("x"))
    Pack.ensure(server)

    assert await_final() == {:error, {:http_status, 404}}
    assert File.read!(Path.join(root, @version <> ".tar.gz.part")) == ""
  end

  @tag capture_log: true
  test "a transport error is reported", %{root: root} do
    Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))
    server = start_pack(root, pin("x"))
    Pack.ensure(server)

    assert await_final() == {:error, {:transport, :econnrefused}}
  end

  @tag capture_log: true
  test "a disk error is {:io, reason}", %{root: root} do
    File.mkdir_p!(Path.dirname(root))
    File.write!(root, "a file where the root dir should be")

    server = start_pack(root, pin("x"))
    Pack.ensure(server)

    assert {:error, {:io, reason}} = await_final()
    assert is_atom(reason)
  end

  @tag capture_log: true
  test "a crashing download task becomes an error", %{root: root} do
    Req.Test.stub(@stub, fn _conn -> raise "boom" end)
    server = start_pack(root, pin("x"))
    Pack.ensure(server)

    assert await_final() == {:error, {:crashed, %RuntimeError{message: "boom"}}}
    refute match?({:downloading, _}, Pack.status(server))
  end

  for {label, name} <- [
        {"a .. segment", "../escape.txt"},
        {"a nested .. segment", "presets/../../escape.txt"},
        {"an absolute path", "/tmp/escape.txt"}
      ] do
    @tag capture_log: true
    test "rejects a tarball with #{label}", %{root: root, src: src, tmp_dir: tmp_dir} do
      body = tarball(src, [{"manifest.json", "{}"}, {unquote(name), "pwned"}])
      serve(body)
      server = start_pack(root, pin(body))
      Pack.ensure(server)

      assert await_final() == {:error, {:unsafe_entry, unquote(name)}}
      refute File.exists?(Path.join(root, @version))
      refute File.exists?(Path.join(root, @version <> ".tmp"))
      refute File.exists?(Path.join(root, "escape.txt"))
      refute File.exists?(Path.join(tmp_dir, "escape.txt"))
    end
  end

  @tag capture_log: true
  test "rejects a tarball with a symlink", %{root: root, src: src} do
    File.mkdir_p!(src)
    link = Path.join(src, "link")
    File.ln_s!("/etc", link)
    path = Path.join(src, "symlink.tar.gz")

    :ok =
      :erl_tar.create(
        to_charlist(path),
        [{~c"manifest.json", "{}"}, {~c"presets", to_charlist(link)}],
        [:compressed]
      )

    body = File.read!(path)
    serve(body)
    server = start_pack(root, pin(body))
    Pack.ensure(server)

    assert await_final() == {:error, {:unsafe_entry, "presets"}}
  end

  @tag capture_log: true
  test "rejects a tarball without manifest.json at its root", %{root: root, src: src} do
    body = tarball(src, [{"pack/manifest.json", "{}"}])
    serve(body)
    server = start_pack(root, pin(body))
    Pack.ensure(server)

    assert await_final() == {:error, :missing_manifest}
    refute File.exists?(Path.join(root, @version))
  end

  test "removes other versions and stale downloads, keeps other files", %{root: root, src: src} do
    File.mkdir_p!(Path.join(root, "2026.10.1"))
    File.write!(Path.join(root, "2026.10.1/manifest.json"), "{}")
    File.write!(Path.join(root, "2026.10.1.tar.gz.part"), "old")
    File.mkdir_p!(Path.join(root, "2026.10.1.tmp"))
    File.write!(Path.join(root, "settings.dets"), "store")

    body = good_pack(src)
    serve(body)
    server = start_pack(root, pin(body))
    Pack.ensure(server)

    assert {:ready, @version, _} = await_final()
    assert File.ls!(root) |> Enum.sort() == [@version, "settings.dets"]
  end

  @tag capture_log: true
  test "a failed attempt can be retried with ensure/1", %{root: root, src: src} do
    body = good_pack(src)
    Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    server = start_pack(root, pin(body))

    Pack.ensure(server)
    assert await_final() == {:error, {:http_status, 503}}

    serve(body)
    assert {:downloading, 0} = Pack.ensure(server)
    assert {:ready, @version, _} = await_final()
  end

  # As UniversalProxy.MilkDrop.Supervisor runs it: the download's Task
  # supervisor and Pack, :one_for_all.
  @tag capture_log: true
  test "a Pack killed mid-download restarts absent and announces it", %{root: root, src: src} do
    body = good_pack(src)
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:request, self()})

      receive do
        :go -> Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    tasks = :"#{inspect(__MODULE__)}.KillTasks"

    children = [
      {Task.Supervisor, name: tasks},
      {Pack,
       name: nil,
       root: root,
       pin: pin(body),
       task_supervisor: tasks,
       req_options: [plug: {Req.Test, @stub}]}
    ]

    sup =
      start_supervised!(%{
        id: :pack_unit,
        type: :supervisor,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
      })

    pack = fn ->
      Enum.find_value(Supervisor.which_children(sup), fn
        {Pack, pid, _, _} -> pid
        _ -> nil
      end)
    end

    old = pack.()
    # The first Pack's own announcement, so the one below is the replacement's.
    assert_receive {:milkdrop_pack_started, :absent}, 5_000

    assert {:downloading, 0} = Pack.ensure(old)
    assert_receive {:request, handler}
    handler_ref = Process.monitor(handler)

    Process.exit(old, :kill)
    assert_receive {:milkdrop_pack_started, :absent}, 5_000
    # The download died with it.
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _}, 5_000
    new = pack.()
    assert is_pid(new) and new != old
    assert Pack.status(new) == :absent

    # And it can be asked again.
    assert {:downloading, 0} = Pack.ensure(new)
    assert_receive {:request, handler}
    send(handler, :go)
    assert {:ready, @version, _} = await_final()
  end

  test "the public API reports :not_running when the server is down" do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}

    assert Pack.status(dead) == {:error, :not_running}
    assert Pack.ensure(dead) == {:error, :not_running}
  end
end
