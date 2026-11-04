exclude = if Circuits.CEC.TestSupport.helpers_available?(), do: [], else: [:helper]
ExUnit.start(exclude: exclude)
