defmodule UniversalProxy.FirmwareUpdate.GithubClientTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.GithubClient

  defp stub_plug(handler) when is_function(handler, 1) do
    [plug: handler]
  end

  defp respond(conn, status, body, headers \\ []) do
    conn =
      Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)

    case body do
      nil ->
        Plug.Conn.send_resp(conn, status, "")

      json when is_map(json) or is_list(json) ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(json))

      bin when is_binary(bin) ->
        Plug.Conn.send_resp(conn, status, bin)
    end
  end

  describe "latest_release/2" do
    test "decodes a stable release with assets + etag" do
      handler = fn conn ->
        assert conn.request_path == "/repos/owner/repo/releases/latest"

        respond(
          conn,
          200,
          %{
            "tag_name" => "v1.2.3",
            "name" => "v1.2.3",
            "body" => "## Notes",
            "published_at" => "2026-05-15T12:00:00Z",
            "prerelease" => false,
            "assets" => [
              %{
                "name" => "universal_proxy_rpi3.fw",
                "url" => "https://api.example/assets/1",
                "browser_download_url" => "https://dl.example/1.fw",
                "size" => 1024
              }
            ]
          },
          [{"etag", "W/\"abc\""}]
        )
      end

      assert {:ok, release} =
               GithubClient.latest_release("owner/repo", req_options: stub_plug(handler))

      assert release.tag_name == "v1.2.3"
      assert release.body == "## Notes"
      assert release.etag == "W/\"abc\""
      assert [%{name: "universal_proxy_rpi3.fw", size: 1024}] = release.assets
    end

    test "304 Not Modified returns {:ok, :not_modified}" do
      handler = fn conn ->
        assert ["W/\"abc\""] = Plug.Conn.get_req_header(conn, "if-none-match")
        respond(conn, 304, nil)
      end

      assert {:ok, :not_modified} =
               GithubClient.latest_release("owner/repo",
                 etag: "W/\"abc\"",
                 req_options: stub_plug(handler)
               )
    end

    test "404 returns {:error, :not_found}" do
      handler = fn conn -> respond(conn, 404, %{"message" => "Not Found"}) end

      assert {:error, :not_found} =
               GithubClient.latest_release("owner/missing", req_options: stub_plug(handler))
    end

    test "403 with x-ratelimit-remaining: 0 returns {:error, :rate_limited}" do
      handler = fn conn ->
        respond(conn, 403, %{"message" => "limit"}, [{"x-ratelimit-remaining", "0"}])
      end

      assert {:error, :rate_limited} =
               GithubClient.latest_release("owner/repo", req_options: stub_plug(handler))
    end

    test "prerelease results are filtered out" do
      handler = fn conn ->
        respond(conn, 200, %{
          "tag_name" => "v2.0.0-rc1",
          "name" => "rc",
          "body" => "",
          "published_at" => "2026-05-15T00:00:00Z",
          "prerelease" => true,
          "assets" => []
        })
      end

      assert {:error, :no_stable_release} =
               GithubClient.latest_release("owner/repo", req_options: stub_plug(handler))
    end

    test "github_token is forwarded as Authorization: Bearer" do
      handler = fn conn ->
        assert ["Bearer secret-token"] = Plug.Conn.get_req_header(conn, "authorization")
        respond(conn, 304, nil)
      end

      assert {:ok, :not_modified} =
               GithubClient.latest_release("owner/repo",
                 github_token: "secret-token",
                 etag: "x",
                 req_options: stub_plug(handler)
               )
    end
  end

  describe "download_asset/3" do
    setup do
      tmp = System.tmp_dir!()
      unique = System.unique_integer([:positive])
      dest = Path.join(tmp, "asset_test_#{unique}.bin")

      on_exit(fn ->
        File.rm(dest)
        File.rm(dest <> ".part")
      end)

      {:ok, dest: dest}
    end

    test "writes the response body to dest atomically", %{dest: dest} do
      payload = :crypto.strong_rand_bytes(2048)

      handler = fn conn ->
        respond(conn, 200, payload)
      end

      assert :ok =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 expected_size: byte_size(payload),
                 req_options: stub_plug(handler)
               )

      assert File.read!(dest) == payload
      refute File.exists?(dest <> ".part")
    end

    test "fires progress callback at least on completion", %{dest: dest} do
      payload = :crypto.strong_rand_bytes(1024)
      test_pid = self()

      handler = fn conn -> respond(conn, 200, payload) end

      progress = fn event -> send(test_pid, {:progress, event}) end

      assert :ok =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 expected_size: byte_size(payload),
                 progress: progress,
                 req_options: stub_plug(handler)
               )

      assert_received {:progress, {:downloading, 100}}
    end

    test "non-2xx response deletes the part file and returns error", %{dest: dest} do
      handler = fn conn -> respond(conn, 500, "boom") end

      assert {:error, {:unexpected_status, 500}} =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 req_options: stub_plug(handler) ++ [retry: false]
               )

      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end
  end
end
