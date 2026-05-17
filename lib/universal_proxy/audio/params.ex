defmodule UniversalProxy.Audio.Params do
  @moduledoc false

  # Internal helper for normalising form/API input that may arrive
  # with atom keys (Elixir callers) or string keys (LiveView form
  # params). Both `Audio.Server.sanitize_update/1` and
  # `Audio.Store.merge_defaults/3` need the same atom/string fallback
  # pattern, and previously implemented it twice — keeping them in
  # sync is what this module exists for.

  @doc """
  Build a map containing only the atoms in `keys` whose value is
  present in `params` under either the atom or the equivalent string
  key. Atom-keyed entries win over string-keyed entries.
  """
  @spec take(map(), [atom()]) :: map()
  def take(params, keys) when is_map(params) and is_list(keys) do
    Enum.reduce(keys, %{}, fn k, acc ->
      cond do
        Map.has_key?(params, k) ->
          Map.put(acc, k, Map.get(params, k))

        Map.has_key?(params, Atom.to_string(k)) ->
          Map.put(acc, k, Map.get(params, Atom.to_string(k)))

        true ->
          acc
      end
    end)
  end

  @doc """
  Like `Map.has_key?/2` but also true for the equivalent string key.
  """
  @spec has_key?(map(), atom()) :: boolean()
  def has_key?(params, key) when is_map(params) and is_atom(key) do
    Map.has_key?(params, key) or Map.has_key?(params, Atom.to_string(key))
  end

  @doc """
  Like `Map.get/3` but also looks up the equivalent string key. Atom
  match wins over string match.
  """
  @spec get(map(), atom(), term()) :: term()
  def get(params, key, default \\ nil) when is_map(params) and is_atom(key) do
    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, Atom.to_string(key)) -> Map.get(params, Atom.to_string(key))
      true -> default
    end
  end
end
