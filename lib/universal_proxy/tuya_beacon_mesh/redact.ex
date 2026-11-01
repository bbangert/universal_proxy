defmodule UniversalProxy.TuyaBeaconMesh.Redact do
  @moduledoc """
  Keeps mesh keys out of process status, debug events, replies and crash
  reasons, for the processes that hold an inventory (`Lights`).

    * `seal/1` wraps a term in an opaque closure, which every printer
      (`Inspect`, `~p`, crash reports, the raw `:sys` debug log and
      `:sys.get_state/1`, none of which `format_status/1` reaches) shows as
      a bare function. `unseal/1` takes it back out, and only opens
      closures `seal/1` made (checked by fun identity): any other
      function passes through uncalled, so a request can't get a caller's
      fun run inside a server.
    * `term/1` is the defence in depth for everything else: it replaces
      anything that may carry keys wherever it sits inside a term — an
      `Inventory` or one of its bulbs, a map with a `beaconKey`/`localKey`
      field in any spelling (string or atom, camel or snake case, any
      letter case), a binary or charlist naming such a field (inventory
      JSON), and a 32-hex-digit binary (a key's shape; MACs are 12).
      Exceptions shrink to their module (their fields, such as a
      `FunctionClauseError`'s arguments, may hold anything).
    * `request/2` and `message/2` redact the second element of the
      requests tagged in `tags` (the inventory argument, in whatever
      representation) by position, then apply `term/1`.
    * `format_status/2` applies both to a gen_server's state, last
      message, queue, debug log and crash reason, with stack frames cut to
      arities.
    * `guard/2` runs a callback body that has keys in scope. Raised
      exceptions and their stack frames can carry them (a BIF error or a
      `FunctionClauseError` keeps the top frame's arguments), and the exit
      reason a crash leaves reaches supervisor reports and links
      unformatted, so anything raised, thrown or exited is re-raised as a
      key-free `UniversalProxy.TuyaBeaconMesh.Redact.Error`.

  Core-only: nothing here depends on the host.
  """

  alias UniversalProxy.TuyaBeaconMesh.Inventory

  defmodule Error do
    @moduledoc "A key-free stand-in for whatever a key-handling callback raised."
    defexception [:message]
  end

  # Every spelling Inventory.decode/1 reads a key field under (beaconKey,
  # beacon_key, localKey, local_key) and then some: any case, `-` too.
  @key_name ~r/(beacon|local)[_-]?key/i
  @key_shape ~r/\A[0-9A-Fa-f]{32}\z/

  @doc "`term` with every key-bearing part replaced by `:redacted`."
  @spec term(term()) :: term()
  def term(%Inventory{}), do: :redacted
  def term(%Inventory.Bulb{}), do: :redacted
  # Built key-free by guard/2.
  def term(%Error{} = error), do: error
  def term(%{__exception__: true, __struct__: module}), do: {:exception, module}
  # Other structs (pids in from-tuples, refs, Seq) carry no inventory.
  def term(%_{} = struct), do: struct

  def term(map) when is_map(map) do
    if Enum.any?(Map.keys(map), &key_name?/1),
      do: :redacted,
      else: Map.new(map, fn {k, v} -> {term(k), term(v)} end)
  end

  def term(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&term/1) |> List.to_tuple()

  def term(binary) when is_binary(binary) do
    if Regex.match?(@key_name, binary) or Regex.match?(@key_shape, binary),
      do: :redacted,
      else: binary
  end

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

  @doc """
  What `seal/1` wrapped; anything else as is. A fun is opened only when it
  is the closure `seal/1` builds (a local fun with that closure's module,
  index and code hash), so no other fun is ever called: not another
  module's, not an external capture such as `&Redact.module_info/0`.
  """
  @spec unseal(term()) :: term()
  def unseal(sealed) when is_function(sealed, 0) do
    if identity(sealed) == identity(seal(nil)), do: sealed.(), else: sealed
  end

  def unseal(other), do: other

  # An external fun has no index or code hash, so it never matches.
  defp identity(fun) do
    Enum.map([:type, :module, :new_index, :new_uniq], &Function.info(fun, &1))
  end

  @doc """
  A request (the body of a call, cast or plain message) with the second
  element of one tagged in `tags` redacted by position, then `term/1`.
  """
  @spec request(term(), [atom()]) :: term()
  def request(request, tags \\ [])

  def request(request, tags) when is_tuple(request) and tuple_size(request) >= 2 do
    if elem(request, 0) in tags,
      do: request |> put_elem(1, :redacted) |> term(),
      else: term(request)
  end

  def request(request, _tags), do: term(request)

  @doc "A mailbox message (a call, a cast, or anything else) through `request/2`."
  @spec message(term(), [atom()]) :: term()
  def message(message, tags \\ [])
  def message({:"$gen_call", from, req}, tags), do: {:"$gen_call", from, request(req, tags)}
  def message({:"$gen_cast", req}, tags), do: {:"$gen_cast", request(req, tags)}
  def message(other, tags), do: request(other, tags)

  @doc """
  A gen_server `format_status/1` built on `term/1`; `tags` as in
  `request/2`.
  """
  @spec format_status(map(), [atom()]) :: map()
  def format_status(status, tags \\ []) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, reason(reason)}
      {:message, message} -> {:message, message(message, tags)}
      {:queue, queue} when is_list(queue) -> {:queue, Enum.map(queue, &message(&1, tags))}
      # sys events ({:in, msg}, {:in, msg, from}, {:out, reply, to, state}, ...).
      {:log, log} when is_list(log) -> {:log, Enum.map(log, &log_event(&1, tags))}
      {key, value} when key in [:state, :queue, :log] -> {key, term(value)}
      other -> other
    end)
  end

  @doc "A crash reason with its stack cut to arities and its terms redacted."
  @spec reason(term()) :: term()
  def reason({reason, [_ | _] = stack} = full) do
    if proper_list?(stack), do: {term(reason), stack(stack)}, else: term(full)
  end

  def reason(reason), do: term(reason)

  @doc "Stack frames without their arguments."
  @spec stack(list()) :: list()
  def stack(stack) when is_list(stack), do: Enum.map(stack, &arity_frame/1)

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

  defp log_event(event, tags) when is_tuple(event),
    do: event |> Tuple.to_list() |> Enum.map(&message(&1, tags)) |> List.to_tuple()

  defp log_event(event, _tags), do: term(event)

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
