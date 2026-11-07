defmodule UniversalProxy.SafeMdns do
  @moduledoc """
  Runs one call against an `MdnsLite`-shaped module, mapping failure to
  `{:error, :mdns_unavailable}`.

  `MdnsLite`'s functions are `GenServer.call`s into the TableServer: a
  stopped or restarting MdnsLite exits rather than raising, and an
  unstarted `MdnsLite.Responders` registry raises `ArgumentError`. Both
  shapes have to be caught or an mDNS hiccup takes the calling subsystem
  down with it.
  """

  require Logger

  @spec call(module(), (module() -> result)) :: result | {:error, :mdns_unavailable}
        when result: term()
  def call(mdns_module, fun) when is_function(fun, 1) do
    fun.(mdns_module)
  rescue
    e ->
      Logger.debug("#{inspect(mdns_module)} call raised: #{Exception.message(e)}")
      {:error, :mdns_unavailable}
  catch
    :exit, reason ->
      Logger.debug("#{inspect(mdns_module)} call exited: #{inspect(reason)}")
      {:error, :mdns_unavailable}
  end
end
