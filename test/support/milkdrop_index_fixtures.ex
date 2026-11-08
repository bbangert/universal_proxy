defmodule UniversalProxy.MilkDropIndexFixtures do
  @moduledoc """
  On-disk fixtures for `UniversalProxy.MilkDrop.Index` and the preset
  browser: an extracted pack (`<root>/<version>/manifest.json`) and
  uploads already in the library (`<root>/user/presets/`), which
  `UniversalProxy.MilkDrop.UserPresets` picks up when it starts.
  """

  import UniversalProxy.MilkDropUploadFixtures, only: [milk: 0]

  @doc """
  Writes a pack manifest listing `entries` (maps in the manifest's JSON
  shape, or plain ids) and returns its directory.
  """
  @spec write_pack!(String.t(), String.t(), [map() | String.t()]) :: String.t()
  def write_pack!(root, version, entries) do
    dir = Path.join(root, version)
    File.mkdir_p!(dir)

    presets =
      Enum.map(entries, fn
        id when is_binary(id) -> %{"file" => id}
        entry -> entry
      end)

    manifest = %{"format" => 1, "version" => version, "presets" => presets}
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
    dir
  end

  @doc "Puts uploads named `names` (`\"X.milk\"`) into the library under `root`."
  @spec seed_uploads!(String.t(), [String.t()]) :: :ok
  def seed_uploads!(root, names) do
    dir = Path.join([root, "user", "presets"])
    File.mkdir_p!(dir)
    Enum.each(names, &File.write!(Path.join(dir, &1), milk()))
  end

  @doc "`n` pack ids, `\"Preset 001.milk\"` …, in name order."
  @spec pack_ids(pos_integer()) :: [String.t()]
  def pack_ids(n),
    do: for(i <- 1..n, do: "Preset #{String.pad_leading(Integer.to_string(i), 3, "0")}.milk")
end
