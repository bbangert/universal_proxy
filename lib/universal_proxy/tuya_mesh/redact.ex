defmodule UniversalProxy.TuyaMesh.Redact do
  @moduledoc """
  Keeps mesh keys out of process status, debug logs and crash reasons, for
  the processes that receive inventories (`Store`, `Resolver`).

    * `seal/1` wraps an inventory for sending as a message: a closure, which
      every printer (`Inspect`, `~p`, crash reports, the raw `:sys` debug
      log, which `format_status/1` never sees) shows as an opaque
      function. The client APIs of `Store` and `Resolver` send inventories
      only this way, and `Store.load/1`'s reply travels sealed too (the
      debug log records replies as well); `unseal/1` takes it back out in
      the caller (and passes anything else through, for direct calls).
    * `request/1` redacts by shape: the inventory argument of every request
      that carries one (`:replace`, `:persist`, `:classify`, `:preview`;
      `tighten` travels as `:persist`) becomes `:redacted`, whatever its
      representation — struct, map with any key style, or a JSON binary.
    * `term/1` is the defence in depth for everything else: it replaces
      anything that may carry keys wherever it sits inside a term — an
      `Inventory` or one of its bulbs, a map with a `beaconKey`/`localKey`
      field in any spelling (string or atom, camel or snake case, any
      letter case), and a binary or charlist naming such a field (inventory
      JSON). Exceptions shrink to their module (their fields, such as a
      `FunctionClauseError`'s arguments, may hold anything).
    * `format_status/1` applies both to a gen_server's state, last message,
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

  # Every spelling Inventory.decode/1 reads a key field under (beaconKey,
  # beacon_key, localKey, local_key) and then some: any case, `-` too.
  @key_name ~r/(beacon|local)[_-]?key/i

  # Requests whose second element is an inventory in any representation.
  @inventory_requests [:replace, :persist, :classify, :preview]

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
    if Enum.any?(Map.keys(map), &key_name?/1),
      do: :redacted,
      else: Map.new(map, fn {k, v} -> {term(k), term(v)} end)
  end

  def term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&term/1) |> List.to_tuple()

  def term(binary) when is_binary(binary),
    do: if(Regex.match?(@key_name, binary), do: :redacted, else: binary)

  def term(list) when is_list(list) do
    cond do
      not proper_list?(list) -> :redacted
      charlist_naming_key?(list) -> :redacted
      true -> Enum.map(list, &term/1)
    end
  end

  def term(other), do: other

  @doc "Wraps `term` in an opaque closure (see the moduledoc)."
  @spec seal(term()) :: (-> term())
  def seal(term), do: fn -> term end

  @doc "What `seal/1` wrapped; anything else as is."
  @spec unseal(term()) :: term()
  def unseal(sealed) when is_function(sealed, 0), do: sealed.()
  def unseal(other), do: other

  @doc """
  A request (the body of a call, cast or plain message) with the inventory
  of an inventory-carrying request redacted by position, then `term/1`.
  """
  @spec request(term()) :: term()
  def request({tag, _inventory}) when tag in @inventory_requests, do: {tag, :redacted}

  def request({tag, _inventory, rest}) when tag in @inventory_requests,
    do: {tag, :redacted, term(rest)}

  def request(other), do: term(other)

  @doc "A mailbox message (a call, a cast, or anything else) through `request/1`."
  @spec message(term()) :: term()
  def message({:"$gen_call", from, request}), do: {:"$gen_call", from, request(request)}
  def message({:"$gen_cast", request}), do: {:"$gen_cast", request(request)}
  def message(other), do: request(other)

  @doc "A gen_server `format_status/1` built on `term/1`."
  @spec format_status(map()) :: map()
  def format_status(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, reason(reason)}
      {:message, message} -> {:message, message(message)}
      {:queue, queue} when is_list(queue) -> {:queue, Enum.map(queue, &message/1)}
      # sys events ({:in, msg}, {:in, msg, from}, {:out, reply, to}, ...).
      {:log, log} when is_list(log) -> {:log, Enum.map(log, &log_event/1)}
      {key, value} when key in [:state, :queue, :log] -> {key, term(value)}
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

  defp log_event(event) when is_tuple(event),
    do: event |> Tuple.to_list() |> Enum.map(&message/1) |> List.to_tuple()

  defp log_event(event), do: term(event)

  defp key_name?(key) when is_binary(key), do: Regex.match?(@key_name, key)
  defp key_name?(key) when is_atom(key), do: key |> Atom.to_string() |> key_name?()
  defp key_name?(_key), do: false

  defp charlist_naming_key?(list) do
    List.ascii_printable?(list) and Regex.match?(@key_name, List.to_string(list))
  end

  defp arity_frame({m, f, args, loc}) when is_list(args), do: {m, f, length(args), loc}
  defp arity_frame(frame), do: frame

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_improper), do: false
end
