defmodule UniversalProxy.FirmwareUpdate.GithubClient do
  @moduledoc """
  Stateless HTTP client for GitHub Releases.

  Library-shape: no host dependencies. The progress callback is the
  only seam; consumers translate it into PubSub broadcasts.

  ## Rate limiting

  Anonymous requests are limited to 60/hr per source IP. Pass an
  `If-None-Match` ETag (returned in the previous `latest_release/2`
  response under `:etag`) — 304 responses do not count against quota.

  See: https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
  """

  @api_base "https://api.github.com"
  # Stream download chunks in 256 KiB units, reporting progress to the
  # callback when the cumulative delta crosses this threshold.
  @progress_chunk_bytes 256 * 1024

  @type asset :: %{
          required(:name) => String.t(),
          required(:url) => String.t(),
          required(:size) => non_neg_integer(),
          optional(any()) => any()
        }

  @type release :: %{
          required(:tag_name) => String.t(),
          required(:name) => String.t() | nil,
          required(:body) => String.t(),
          required(:published_at) => String.t(),
          required(:assets) => [asset()],
          required(:etag) => String.t() | nil
        }

  @doc """
  Fetches the latest release for `owner_repo` (e.g. `"bbangert/universal_proxy"`).

  ## Options

    * `:channel` — `:stable` (default) or `:prerelease`.
      `:stable` hits the `/releases/latest` endpoint — GitHub's "latest"
      excludes prereleases and drafts by definition, so the existing
      prerelease guard is just belt-and-suspenders.
      `:prerelease` hits `/releases?per_page=30` and picks the release
      with the highest semver tag (drafts excluded, prereleases
      eligible — ties are broken by `Version.compare/2`'s native
      prerelease ordering, so e.g. `v1.3.0-rc.1` beats `v1.2.9`).
    * `:github_token` — optional bearer token for higher rate limits and
      private-repo access.
    * `:etag` — value from a prior call's response. A matching server
      response returns `{:ok, :not_modified}` without counting against
      quota.
    * `:req_options` — extra options forwarded to `Req.new/1` (used by
      tests to inject `plug:` for stubbing).

  Returns `{:ok, release}` on a current release, `{:ok, :not_modified}`
  on 304, `{:error, :no_release}` when `:channel` is `:prerelease` and
  no release has a parseable semver tag, `{:error, :rate_limited}` on
  quota exhaustion, `{:error, :not_found}` on 404, or `{:error, term()}`
  on transport errors.
  """
  @spec latest_release(String.t(), keyword()) ::
          {:ok, release()} | {:ok, :not_modified} | {:error, term()}
  def latest_release(owner_repo, opts \\ []) when is_binary(owner_repo) do
    channel = Keyword.get(opts, :channel, :stable)
    url = release_url(owner_repo, channel)

    headers =
      [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
      |> add_auth(opts[:github_token])
      |> add_if_none_match(opts[:etag])

    req_opts =
      [url: url, headers: headers]
      |> Keyword.merge(Keyword.get(opts, :req_options) || [])

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 200, body: body, headers: resp_headers}} ->
        decode_latest(channel, body, resp_headers)

      {:ok, %Req.Response{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 403, headers: resp_headers}} ->
        if rate_limited?(resp_headers) do
          {:error, :rate_limited}
        else
          {:error, {:forbidden, resp_headers}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams an asset to `dest_path`, writing atomically (`.part` → rename).

  Reports progress through `opts[:progress]` as `{:downloading, percent}`
  every ≥ #{@progress_chunk_bytes} bytes and once on completion.

  ## Options

    * `:expected_sha256` — optional hex digest (either case) checked
      against a SHA-256 computed incrementally while streaming. Verified
      before the `.part` → dest rename; on mismatch the `.part` file is
      deleted and `{:error, {:sha256_mismatch, expected: ..., actual:
      ...}}` is returned (both hex strings lowercase). Omit to skip
      hashing entirely.

  Returns `:ok` on success; on failure deletes the partial file and
  returns `{:error, term()}`.
  """
  @spec download_asset(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def download_asset(asset_url, dest_path, opts \\ []) when is_binary(asset_url) do
    part_path = dest_path <> ".part"
    total_size = Keyword.get(opts, :expected_size, 0)
    progress_fn = Keyword.get(opts, :progress, fn _ -> :ok end)
    expected_sha256 = opts[:expected_sha256]

    headers =
      [{"accept", "application/octet-stream"}]
      |> add_auth(opts[:github_token])

    File.rm(part_path)
    File.rm(dest_path)

    with {:ok, fd} <- File.open(part_path, [:write, :binary]) do
      acc = %{
        fd: fd,
        written: 0,
        last_reported: 0,
        total: total_size,
        progress_fn: progress_fn,
        hash: hash_init(expected_sha256)
      }

      req_opts =
        [url: asset_url, headers: headers, into: stream_collector(acc)]
        |> Keyword.merge(Keyword.get(opts, :req_options) || [])

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
          File.close(fd)
          progress_fn.({:downloading, 100})
          final_acc = Map.get(resp.private, :gh_acc, acc)

          case verify_sha256(final_acc.hash, expected_sha256) do
            :ok ->
              case File.rename(part_path, dest_path) do
                :ok ->
                  :ok

                {:error, reason} ->
                  File.rm(part_path)
                  {:error, reason}
              end

            {:error, _reason} = error ->
              File.rm(part_path)
              error
          end

        {:ok, %Req.Response{status: status}} ->
          File.close(fd)
          File.rm(part_path)
          {:error, {:unexpected_status, status}}

        {:error, reason} ->
          File.close(fd)
          File.rm(part_path)
          {:error, reason}
      end
    end
  end

  # -- Private --

  defp stream_collector(initial_acc) do
    fn {:data, chunk}, {request, %Req.Response{private: private} = response} ->
      acc = Map.get(private, :gh_acc, initial_acc)
      :ok = IO.binwrite(acc.fd, chunk)

      hash = acc.hash && :crypto.hash_update(acc.hash, chunk)

      new_written = acc.written + byte_size(chunk)
      delta = new_written - acc.last_reported

      acc =
        if delta >= @progress_chunk_bytes and acc.total > 0 do
          pct = min(round(new_written * 100 / acc.total), 99)
          acc.progress_fn.({:downloading, pct})
          %{acc | written: new_written, last_reported: new_written, hash: hash}
        else
          %{acc | written: new_written, hash: hash}
        end

      {:cont, {request, %{response | private: Map.put(private, :gh_acc, acc)}}}
    end
  end

  defp hash_init(nil), do: nil
  defp hash_init(_expected_sha256), do: :crypto.hash_init(:sha256)

  defp verify_sha256(_hash, nil), do: :ok

  defp verify_sha256(hash, expected) do
    actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    expected_lower = String.downcase(expected)

    if actual == expected_lower do
      :ok
    else
      {:error, {:sha256_mismatch, expected: expected_lower, actual: actual}}
    end
  end

  defp release_url(owner_repo, :stable), do: "#{@api_base}/repos/#{owner_repo}/releases/latest"

  defp release_url(owner_repo, :prerelease),
    do: "#{@api_base}/repos/#{owner_repo}/releases?per_page=30"

  defp decode_latest(:stable, body, resp_headers), do: decode_release(body, resp_headers)

  defp decode_latest(:prerelease, body, resp_headers) when is_list(body) do
    case pick_max_semver(body) do
      nil -> {:error, :no_release}
      release -> {:ok, build_release(release, resp_headers)}
    end
  end

  defp decode_latest(:prerelease, _body, _resp_headers), do: {:error, :invalid_response}

  defp pick_max_semver(releases) do
    releases
    |> Enum.reject(&(&1["draft"] == true))
    |> Enum.flat_map(fn release ->
      case parse_semver_tag(release["tag_name"]) do
        {:ok, version} -> [{version, release}]
        :error -> []
      end
    end)
    |> Enum.max_by(fn {version, _release} -> version end, Version, fn -> nil end)
    |> case do
      nil -> nil
      {_version, release} -> release
    end
  end

  defp parse_semver_tag(tag) when is_binary(tag) do
    case Version.parse(String.replace_prefix(tag, "v", "")) do
      {:ok, version} -> {:ok, version}
      :error -> :error
    end
  end

  defp parse_semver_tag(_tag), do: :error

  defp decode_release(body, resp_headers) when is_map(body) do
    if body["prerelease"] == true do
      {:error, :no_stable_release}
    else
      {:ok, build_release(body, resp_headers)}
    end
  end

  defp decode_release(_body, _headers), do: {:error, :invalid_response}

  defp build_release(body, resp_headers) do
    assets =
      body
      |> Map.get("assets", [])
      |> Enum.map(fn a ->
        %{
          name: a["name"],
          url: a["url"],
          browser_download_url: a["browser_download_url"],
          size: a["size"] || 0
        }
      end)

    %{
      tag_name: body["tag_name"],
      name: body["name"],
      body: body["body"] || "",
      published_at: body["published_at"],
      assets: assets,
      etag: header_value(resp_headers, "etag")
    }
  end

  defp add_auth(headers, nil), do: headers
  defp add_auth(headers, ""), do: headers

  defp add_auth(headers, token) when is_binary(token) do
    [{"authorization", "Bearer #{token}"} | headers]
  end

  defp add_if_none_match(headers, nil), do: headers
  defp add_if_none_match(headers, ""), do: headers

  defp add_if_none_match(headers, etag) when is_binary(etag) do
    [{"if-none-match", etag} | headers]
  end

  defp rate_limited?(headers) do
    case header_value(headers, "x-ratelimit-remaining") do
      "0" -> true
      _ -> false
    end
  end

  defp header_value(headers, name) when is_map(headers) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: stringify(v)
    end)
  end

  defp stringify(v) when is_binary(v), do: v
  defp stringify([v | _]), do: v
  defp stringify(v), do: to_string(v)
end
