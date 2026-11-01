defmodule UniversalProxy.TuyaMesh.Redact do
  @moduledoc """
  Keeps mesh keys out of process status, debug logs and crash reasons, for
  the processes that receive inventories (`Store`, `Resolver`).

    * `term/1` replaces anything that carries keys — an `Inventory` or one
      of its bulbs, an inventory map in either key style — wherever it sits
      inside a term, and reduces exceptions to their module (their fields,
      such as a `FunctionClauseError`'s arguments, may hold anything).
    * `format_status/1` applies it to a gen_server's state, last message,
      queue, debug log and crash reason, with stack frames cut to arities.
    * `guard/2` runs a callback body that has an inventory in scope. Raised
      exceptions and their stack frames can carry it, and the exit reason a
      crash leaves reaches supervisor reports unformatted, so anything
      raised, thrown or exited is re-raised as a key-free
      `UniversalProxy.TuyaMesh.Redact.Error`.
  """

  alias UniversalProxy.TuyaBeaconMesh.Inventory

  defmodule Error do
    @moduledoc "A key-free stand-in for whatever a key-handling callback raised."
    defexception [:message]
  end

  @key_fields ["beaconKey", "localKey", :beaconKey, :localKey, :beacon_key, :local_key]

  @doc "`term` with every key-bearing part replaced by `:redacted`."
  @spec term(term()) :: term()
  def term(%Inventory{}), do: :redacted
  def term(%Inventory.Bulb{}), do: :redacted
  # Built key-free by guard/2.
  def term(%Error{} = error), do: error
  def term(%{__exception__: true, __struct__: module}), do: {:exception, module}
  # Other structs (pids in from-tuples, refs, DateTimes) carry no inventory.
  def term(%_{} = struct), do: struct

  def term(map) when is_map(map) do
    if Enum.any?(@key_fields, &Map.has_key?(map, &1)),
      do: :redacted,
      else: Map.new(map, fn {k, v} -> {term(k), term(v)} end)
  end

  def term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&term/1) |> List.to_tuple()

  def term(list) when is_list(list) do
    if proper_list?(list), do: Enum.map(list, &term/1), else: :redacted
  end

  def term(other), do: other

  @doc "A gen_server `format_status/1` built on `term/1`."
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, reason(reason)}
      {key, value} when key in [:state, :message, :queue, :log] -> {key, term(value)}
      other -> other
    end)
  end

  @doc "A crash reason with its stack cut to arities and its terms redacted."
  @spec reason(term()) :: term()
  def reason({reason, [_ | _] = stack}) when is_list(stack),
    do: {term(reason), stack(stack)}

  def reason(reason), do: term(reason)

  @doc "Stack frames without their arguments."
  @spec stack(list()) :: list()
  def stack(stack), do: Enum.map(stack, &arity_frame/1)

  @doc """
  Runs `fun`, re-raising anything it raises, throws or exits as a key-free
  `Error` labelled `label` (see the moduledoc).
  """
  @spec guard(String.t(), (-> result)) :: result when result: term()
  def guard(label, fun) do
    fun.()
  rescue
    e ->
      reraise Error, [message: "#{label}: #{inspect(e.__struct__)} raised"], stack(__STACKTRACE__)
  catch
    kind, _value ->
      reraise Error, [message: "#{label}: #{kind}"], stack(__STACKTRACE__)
  end

  defp arity_frame({m, f, args, loc}) when is_list(args), do: {m, f, length(args), loc}
  defp arity_frame(frame), do: frame

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_improper), do: false
end
