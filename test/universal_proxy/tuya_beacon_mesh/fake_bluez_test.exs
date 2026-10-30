defmodule UniversalProxy.TuyaBeaconMesh.FakeBluezTest do
  # Reads module metadata only; touches no FakeBluez state.
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.FakeBluez

  @stand_ins [
    {FakeBluez.Radio, Bluez.Radio},
    {FakeBluez.Mgmt, Bluez.Mgmt},
    {FakeBluez.Rebus, Bluez.Rebus},
    {FakeBluez.DBus, Bluez.DBus},
    {FakeBluez.Receiver, Bluez.AdvertReceiver}
  ]

  @callbacks [:init, :handle_call, :handle_cast, :handle_info, :terminate, :child_spec]

  for {fake, real} <- @stand_ins do
    test "#{inspect(fake)} matches #{inspect(real)}'s functions and arities" do
      fake = unquote(fake)
      real = unquote(real)
      Code.ensure_loaded!(real)

      for {fun, arity} <- fake.__info__(:functions), fun not in @callbacks do
        assert function_exported?(real, fun, arity),
               "#{inspect(real)}.#{fun}/#{arity} does not exist"
      end
    end
  end

  test "every Bluez function Radio calls has a stand-in" do
    used = [
      {FakeBluez.Radio, [subscribe: 0, acquire: 1, release: 1, valid?: 1]},
      {FakeBluez.Mgmt, [read_advertising_features: 1, advertise: 3, stop_advertising: 2]},
      {FakeBluez.Rebus, [connect: 1]},
      {FakeBluez.DBus, [call: 6]},
      {FakeBluez.Receiver, [start_link: 1, listening?: 1]}
    ]

    for {fake, funs} <- used, {fun, arity} <- funs do
      Code.ensure_loaded!(fake)

      assert function_exported?(fake, fun, arity), "#{inspect(fake)}.#{fun}/#{arity} missing"
    end
  end
end
