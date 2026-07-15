defmodule UniversalProxy.FirmwareUpdate.Manifest do
  @moduledoc """
  Parses and validates `release-manifest.json`.

  Source of truth: `docs/manifest-format.md`. This module owns schema
  validation and the two policy checks (counter, expiry) the device
  runs after signature verification; it does not verify the signature
  itself (see `UniversalProxy.FirmwareUpdate.Signature`) or touch the
  filesystem/network.

  Library-shape: pure functions, no host dependencies, no processes.

  ## Counter semantics

  `counter` is a monotonic anchor persisted by the caller in
  `Nerves.Runtime.KV` (`fw_manifest_counter`) after a successful
  flash. `check_counter/2` allows the manifest counter to be **equal**
  to the stored one (reinstalling the current release), rejects a
  **lower** one (rollback), and accepts when nothing is stored yet
  (first-contact trust — same model as the public key baked into
  firmware). A stored value that fails to parse as an integer is
  treated as absent rather than raising: a corrupted KV anchor must
  not permanently brick the update path.

  ## Expiry is policy-gated

  `expires_at` only matters when the caller opts in via
  `enforce_expiry: true` (device-side default off). A dormant project
  — no CI running, no one rotating `expires_at` forward — must not
  have its devices' update path silently brick itself just because a
  manifest aged out.
  """

  @type target :: %{asset: String.t(), sha256: String.t(), size: non_neg_integer()}

  @type t :: %__MODULE__{
          version: 1,
          counter: non_neg_integer(),
          signed_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          targets: %{String.t() => target()},
          deltas: map()
        }

  defstruct [:version, :counter, :signed_at, :expires_at, :targets, :deltas]

  @doc """
  Parses and validates `binary` as a version-1 release manifest.

  Returns `{:ok, t()}` or `{:error, {:invalid_manifest, reason}}` on
  any schema violation (bad JSON, unsupported version, missing/invalid
  fields, empty or malformed `targets`).
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, {:invalid_manifest, term()}}
  def parse(binary) when is_binary(binary) do
    with {:ok, json} <- decode_json(binary),
         {:ok, version} <- fetch_version(json),
         {:ok, counter} <- fetch_counter(json),
         {:ok, signed_at} <- fetch_signed_at(json),
         {:ok, expires_at} <- fetch_expires_at(json),
         {:ok, targets} <- fetch_targets(json) do
      {:ok,
       %__MODULE__{
         version: version,
         counter: counter,
         signed_at: signed_at,
         expires_at: expires_at,
         targets: targets,
         deltas: Map.get(json, "deltas", %{})
       }}
    end
  end

  @doc """
  Looks up a target entry by Nerves platform name.
  """
  @spec target(t(), String.t()) :: {:ok, target()} | {:error, {:target_not_found, String.t()}}
  def target(%__MODULE__{targets: targets}, name) do
    case Map.fetch(targets, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:target_not_found, name}}
    end
  end

  @doc """
  Rejects a manifest whose counter is lower than the persisted anchor.

  `stored` is the raw string read from Nerves KV — `nil`, `""`, or a
  string that fails to parse as an integer are all treated as "no
  anchor yet" and accepted (see moduledoc).
  """
  @spec check_counter(t(), String.t() | nil) ::
          :ok | {:error, {:manifest_rollback, non_neg_integer(), integer()}}
  def check_counter(%__MODULE__{counter: counter}, stored) do
    case parse_stored_counter(stored) do
      :absent ->
        :ok

      {:ok, stored_counter} when counter >= stored_counter ->
        :ok

      {:ok, stored_counter} ->
        {:error, {:manifest_rollback, counter, stored_counter}}
    end
  end

  defp parse_stored_counter(nil), do: :absent
  defp parse_stored_counter(""), do: :absent

  defp parse_stored_counter(stored) when is_binary(stored) do
    case Integer.parse(stored) do
      {int, ""} -> {:ok, int}
      # Garbage anchor: don't let a corrupted KV entry brick updates.
      _ -> :absent
    end
  end

  @doc """
  Rejects an expired manifest, but only when `enforce?` is true.
  """
  @spec check_expiry(t(), boolean(), DateTime.t()) ::
          :ok | {:error, {:manifest_expired, DateTime.t()}}
  def check_expiry(manifest, enforce?, now \\ DateTime.utc_now())

  def check_expiry(%__MODULE__{}, false, _now), do: :ok
  def check_expiry(%__MODULE__{expires_at: nil}, true, _now), do: :ok

  def check_expiry(%__MODULE__{expires_at: expires_at}, true, now) do
    if DateTime.before?(expires_at, now) do
      {:error, {:manifest_expired, expires_at}}
    else
      :ok
    end
  end

  # -- Parsing / validation --

  defp decode_json(binary) do
    case JSON.decode(binary) do
      {:ok, %{} = json} -> {:ok, json}
      {:ok, other} -> {:error, {:invalid_manifest, {:not_an_object, other}}}
      {:error, reason} -> {:error, {:invalid_manifest, {:invalid_json, reason}}}
    end
  end

  defp fetch_version(%{"version" => 1}), do: {:ok, 1}

  defp fetch_version(%{"version" => v}),
    do: {:error, {:invalid_manifest, {:unsupported_version, v}}}

  defp fetch_version(_json), do: {:error, {:invalid_manifest, {:unsupported_version, nil}}}

  defp fetch_counter(%{"counter" => c}) when is_integer(c) and c >= 0, do: {:ok, c}
  defp fetch_counter(%{"counter" => c}), do: {:error, {:invalid_manifest, {:invalid_counter, c}}}
  defp fetch_counter(_json), do: {:error, {:invalid_manifest, :missing_counter}}

  defp fetch_signed_at(%{"signed_at" => s}) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_manifest, {:invalid_signed_at, reason}}}
    end
  end

  defp fetch_signed_at(_json), do: {:error, {:invalid_manifest, :missing_signed_at}}

  defp fetch_expires_at(json) do
    case Map.get(json, "expires_at") do
      nil ->
        {:ok, nil}

      s when is_binary(s) ->
        case DateTime.from_iso8601(s) do
          {:ok, dt, _offset} -> {:ok, dt}
          {:error, reason} -> {:error, {:invalid_manifest, {:invalid_expires_at, reason}}}
        end

      other ->
        {:error, {:invalid_manifest, {:invalid_expires_at, other}}}
    end
  end

  defp fetch_targets(%{"targets" => targets}) when is_map(targets) and map_size(targets) > 0 do
    Enum.reduce_while(targets, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case validate_target(entry) do
        {:ok, valid} -> {:cont, {:ok, Map.put(acc, name, valid)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp fetch_targets(%{"targets" => other}) when is_map(other),
    do: {:error, {:invalid_manifest, :empty_targets}}

  defp fetch_targets(%{"targets" => other}),
    do: {:error, {:invalid_manifest, {:invalid_targets, other}}}

  defp fetch_targets(_json), do: {:error, {:invalid_manifest, :missing_targets}}

  defp validate_target(%{"asset" => asset, "sha256" => sha256, "size" => size})
       when is_binary(asset) and asset != "" and is_integer(size) and size >= 0 do
    case normalize_sha256(sha256) do
      {:ok, normalized} -> {:ok, %{asset: asset, sha256: normalized, size: size}}
      :error -> {:error, {:invalid_manifest, {:invalid_sha256, sha256}}}
    end
  end

  defp validate_target(other), do: {:error, {:invalid_manifest, {:invalid_target_entry, other}}}

  defp normalize_sha256(sha256) when is_binary(sha256) and byte_size(sha256) == 64 do
    lower = String.downcase(sha256)

    if String.match?(lower, ~r/^[0-9a-f]{64}$/) do
      {:ok, lower}
    else
      :error
    end
  end

  defp normalize_sha256(_other), do: :error
end
