defmodule UniversalProxy.Bluetooth.Radios do
  @moduledoc """
  Bluetooth adapter (radio) enumeration from sysfs.

  sysfs (`/sys/class/bluetooth/hci*/`) is the discovery source that works
  regardless of whether `bluetoothd` is running — the kernel creates these
  entries as soon as a controller binds, so the radio list (and MAC → hciX
  resolution) is available even while the BlueZ subtree is stopped or the
  daemon is still coming up.

  Addresses are normalized to uppercase `AA:BB:CC:DD:EE:FF` — the same form
  `UniversalProxy.Bluetooth.Settings` persists, so resolution is a plain
  string compare. An all-zero address (controller not yet initialized by
  the kernel) reads back as `nil`.

  The sysfs root is a parameter so host tests can point at a fixture tree.
  """

  @default_root "/sys/class/bluetooth"

  @type adapter :: %{hci: String.t(), address: String.t() | nil}

  @doc """
  List the controllers the kernel knows about, sorted by hci index.

  Returns `[]` when the sysfs class directory is missing (host, or a board
  with no controller bound yet).
  """
  @spec sysfs_adapters(Path.t()) :: [adapter()]
  def sysfs_adapters(root \\ @default_root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^hci\d+$/, &1))
        |> Enum.sort_by(&hci_index/1)
        |> Enum.map(fn hci -> %{hci: hci, address: read_address(root, hci)} end)

      {:error, _} ->
        []
    end
  end

  @doc ~S|The numeric index of an `"hciX"` name (`"hci10"` → `10`).|
  @spec hci_index(String.t()) :: non_neg_integer()
  def hci_index("hci" <> index), do: String.to_integer(index)

  defp read_address(root, hci) do
    case File.read(Path.join([root, hci, "address"])) do
      {:ok, raw} ->
        case raw |> String.trim() |> String.upcase() do
          # The kernel reports all-zeros until the controller is initialized.
          "00:00:00:00:00:00" -> nil
          "" -> nil
          address -> address
        end

      {:error, _} ->
        nil
    end
  end
end
