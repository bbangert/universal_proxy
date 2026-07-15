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

    test "channel: :prerelease hits the list endpoint and picks the max semver tag, prereleases eligible" do
      handler = fn conn ->
        assert conn.request_path == "/repos/owner/repo/releases"
        assert conn.query_string == "per_page=30"

        respond(
          conn,
          200,
          [
            %{
              "tag_name" => "v1.2.9",
              "name" => "v1.2.9",
              "body" => "old stable",
              "published_at" => "2026-04-01T00:00:00Z",
              "draft" => false,
              "prerelease" => false,
              "assets" => []
            },
            %{
              "tag_name" => "v1.3.0-rc.1",
              "name" => "v1.3.0-rc.1",
              "body" => "release candidate",
              "published_at" => "2026-05-01T00:00:00Z",
              "draft" => false,
              "prerelease" => true,
              "assets" => [
                %{
                  "name" => "universal_proxy_rpi3.fw",
                  "url" => "https://api.example/assets/2",
                  "browser_download_url" => "https://dl.example/2.fw",
                  "size" => 2048
                }
              ]
            },
            %{
              "tag_name" => "v9.9.9",
              "name" => "draft",
              "body" => "should be ignored",
              "published_at" => "2026-06-01T00:00:00Z",
              "draft" => true,
              "prerelease" => false,
              "assets" => []
            },
            %{
              "tag_name" => "not-a-semver",
              "name" => "junk",
              "body" => "should be ignored",
              "published_at" => "2026-06-01T00:00:00Z",
              "draft" => false,
              "prerelease" => false,
              "assets" => []
            }
          ],
          [{"etag", "W/\"list-etag\""}]
        )
      end

      assert {:ok, release} =
               GithubClient.latest_release("owner/repo",
                 channel: :prerelease,
                 req_options: stub_plug(handler)
               )

      assert release.tag_name == "v1.3.0-rc.1"
      assert release.body == "release candidate"
      assert release.etag == "W/\"list-etag\""
      assert [%{name: "universal_proxy_rpi3.fw", size: 2048}] = release.assets
    end

    test "channel: :prerelease with no parseable releases returns {:error, :no_release}" do
      handler = fn conn ->
        respond(conn, 200, [
          %{
            "tag_name" => "not-a-semver",
            "name" => "junk",
            "body" => "",
            "published_at" => "2026-06-01T00:00:00Z",
            "draft" => false,
            "prerelease" => false,
            "assets" => []
          },
          %{
            "tag_name" => "v1.0.0",
            "name" => "draft-only",
            "body" => "",
            "published_at" => "2026-06-01T00:00:00Z",
            "draft" => true,
            "prerelease" => false,
            "assets" => []
          }
        ])
      end

      assert {:error, :no_release} =
               GithubClient.latest_release("owner/repo",
                 channel: :prerelease,
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

    test "matching expected_sha256 succeeds and renames into place", %{dest: dest} do
      payload = :crypto.strong_rand_bytes(4096)
      digest = :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :upper)

      handler = fn conn -> respond(conn, 200, payload) end

      assert :ok =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 expected_sha256: digest,
                 req_options: stub_plug(handler)
               )

      assert File.read!(dest) == payload
      refute File.exists?(dest <> ".part")
    end

    test "wrong expected_sha256 returns {:error, {:sha256_mismatch, ...}} and leaves no files", %{
      dest: dest
    } do
      payload = :crypto.strong_rand_bytes(4096)
      wrong_digest = String.duplicate("0", 64)

      handler = fn conn -> respond(conn, 200, payload) end

      assert {:error, {:sha256_mismatch, expected: expected, actual: actual}} =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 expected_sha256: wrong_digest,
                 req_options: stub_plug(handler)
               )

      assert expected == wrong_digest
      assert actual == :sha256 |> :crypto.hash(payload) |> Base.encode16(case: :lower)
      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end

    test "a response body over the size ceiling aborts the stream and leaves no files", %{
      dest: dest
    } do
      # No :expected_size given ⇒ the ceiling is the bare @min_size_ceiling
      # floor (256 MiB). One byte over it must abort the download before
      # it can fill the download dir. Zero-filled (not random) so building
      # the oversized payload is cheap.
      oversized = 256 * 1024 * 1024 + 1
      payload = :binary.copy(<<0>>, oversized)

      handler = fn conn -> respond(conn, 200, payload) end

      assert {:error, {:download_too_large, _limit}} =
               GithubClient.download_asset(
                 "https://api.example/assets/1",
                 dest,
                 req_options: stub_plug(handler)
               )

      refute File.exists?(dest)
      refute File.exists?(dest <> ".part")
    end
  end
end
