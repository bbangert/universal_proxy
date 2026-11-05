defmodule UniversalProxy.Display.Binding do
  @moduledoc """
  Which audio output and CEC adapter the TV UI follows (D2, P3).

  The output is the one whose player carries the Sendspin display roles
  (`display_roles: true` in `UniversalProxy.Audio.list_outputs/0`, chosen
  by `UniversalProxy.Audio.DisplayRoles`). While no player has them (roles
  off, or the player not up yet) it is the lowest-numbered HDMI output, so
  the mode still has an output to be persisted on. The CEC adapter is the
  one on the same HDMI link: the adapter whose `card_index` is the
  output's ALSA card (`UniversalProxy.Cec.Enumerate` pairs them through
  the shared HDMI sysfs node).
  """

  alias UniversalProxy.Audio.Store
  alias UniversalProxy.Display.Model

  @doc "The binding for these outputs and CEC adapters, or `nil` (no HDMI output)."
  @spec resolve([map()], [map()]) :: Model.binding() | nil
  def resolve(outputs, adapters) when is_list(outputs) and is_list(adapters) do
    case pick_output(outputs) do
      nil ->
        nil

      output ->
        %{
          key: output.key,
          client_id: output_client_id(output),
          cec_dev: cec_dev(Map.get(output, :card_index), adapters)
        }
    end
  end

  defp pick_output(outputs) do
    Enum.find(outputs, &(Map.get(&1, :display_roles) == true)) ||
      outputs
      |> Enum.flat_map(fn
        %{key: key} = output ->
          case Store.hdmi_port(key) do
            nil -> []
            port -> [{port, output}]
          end

        _other ->
          []
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> List.first()
  end

  defp output_client_id(%{client_id: id}) when is_binary(id), do: id
  defp output_client_id(_output), do: nil

  defp cec_dev(card, adapters) when is_integer(card) do
    Enum.find_value(adapters, fn
      %{card_index: ^card, dev: dev} -> dev
      _other -> nil
    end)
  end

  defp cec_dev(_card, _adapters), do: nil

  @doc "Whether a CEC physical address string is a valid one (HPD up, EDID read)."
  @spec valid_phys_addr?(term()) :: boolean()
  def valid_phys_addr?(addr) when is_binary(addr), do: addr != "f.f.f.f"
  def valid_phys_addr?(_addr), do: false
end
