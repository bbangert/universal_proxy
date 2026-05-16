defmodule UniversalProxy.FirmwareUpdate.VersionCompare do
  @moduledoc """
  Compare a GitHub release tag against the device's current firmware
  version.

  Pure functions; intended for use by view helpers that need to decide
  whether to show an "Update available" or "Up to date" badge. Lives
  outside the LiveView so it's unit-testable without standing up the
  full LiveView render pipeline.

  ## Single source of truth

  `compare/2` is the only function that actually inspects the strings.
  `update_available?/2` and `up_to_date?/2` are thin boolean wrappers
  over it — there is **no** second parse-and-fallback path elsewhere.

  ## Comparison rules

  Both sides are normalized by stripping a single leading `v` (so
  `"v1.2.3"` ≡ `"1.2.3"`) and then parsed with `Version.parse/1`.

  - **Either side is `nil`** (no release fetched yet, or no firmware
    version reported): `:missing`. Both boolean wrappers return
    `false` for this — we can't offer an update we don't have.
  - **Both parse as semver**: result of `Version.compare/2`.
  - **Equal after normalization**, but unparseable: `:eq` (so a tag
    like `"nightly-abc"` matching itself reads as "up to date").
  - **Otherwise**: `:incomparable`. Treated by `update_available?/2`
    as "show the option" (matches pre-semver string-inequality
    behavior — better to offer an update we're unsure about than to
    hide it on an unparseable tag).
  """

  @type result :: :gt | :eq | :lt | :missing | :incomparable

  @doc """
  Compare a release tag against a current firmware version. Returns
  one of:

  - `:gt` — release is newer than the device
  - `:eq` — same
  - `:lt` — release is older than the device
  - `:missing` — either input is `nil`
  - `:incomparable` — both inputs are present but at least one
    doesn't parse as semver, and the normalized strings don't match
  """
  @spec compare(String.t() | nil, String.t() | nil) :: result
  def compare(nil, _), do: :missing
  def compare(_, nil), do: :missing

  def compare(release_tag, current_version)
      when is_binary(release_tag) and is_binary(current_version) do
    case {parse(release_tag), parse(current_version)} do
      {{:ok, release}, {:ok, current}} ->
        Version.compare(release, current)

      _ ->
        if normalize(release_tag) == normalize(current_version),
          do: :eq,
          else: :incomparable
    end
  end

  @doc """
  `true` when the release is strictly newer than the device. A
  downgrade (release older than device) returns `false` — that's
  the bug this module exists to prevent.

  When versions can't be compared (e.g. nightly tags), we err on the
  side of showing the option rather than hiding it.
  """
  @spec update_available?(String.t() | nil, String.t() | nil) :: boolean()
  def update_available?(release_tag, current_version) do
    compare(release_tag, current_version) in [:gt, :incomparable]
  end

  @doc """
  `true` when the device is at or ahead of the latest release. The
  "ahead" case is collapsed into the same bucket as "equal" — there
  is no distinct "ahead of latest release" UI state.
  """
  @spec up_to_date?(String.t() | nil, String.t() | nil) :: boolean()
  def up_to_date?(release_tag, current_version) do
    compare(release_tag, current_version) in [:eq, :lt]
  end

  defp parse(s) when is_binary(s), do: s |> normalize() |> Version.parse()
  defp parse(_), do: :error

  defp normalize("v" <> rest), do: rest
  defp normalize(s) when is_binary(s), do: s
  defp normalize(_), do: nil
end
