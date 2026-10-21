defmodule UniversalProxy.Audio.PairingToken do
  @moduledoc """
  Reads a player's Sendspin pairing token from its state dir.

  `sendspin_player` writes the token (`"SP:"` followed by RFC 4648 base32,
  107 characters for the current version) to `pairing_token` in its
  `--state-dir` on every start. It is a long-lived pairing secret: a
  server holding it can pair with the output over the Pairing PSK. It is
  read only on demand, never cached here, and never included in a return
  value other than `{:ok, token}`, so it cannot leak through a logged
  error tuple.
  """

  @filename "pairing_token"

  # The spec caps a token at 127 bytes. Reads stop just past that (room for
  # a trailing newline plus one byte), so a huge file is never loaded; a
  # read that fills the whole buffer means the file is oversized and is
  # rejected before trimming, so trailing content past the limit cannot
  # hide behind whitespace.
  @max_bytes 127
  @read_bytes @max_bytes + 2

  @type error :: :not_ready | :unavailable

  @doc "The token file's name inside a player's state dir."
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc """
  Read and validate the token in `state_dir`.

  `{:error, :not_ready}` when the file does not exist yet (the player has
  never started); `{:error, :unavailable}` when it cannot be read or does
  not hold a well-formed token.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, error()}
  def read(state_dir) when is_binary(state_dir) do
    path = Path.join(state_dir, @filename)

    case File.open(path, [:read, :binary], &IO.binread(&1, @read_bytes)) do
      {:ok, data} when byte_size(data) == @read_bytes -> {:error, :unavailable}
      {:ok, data} when is_binary(data) -> validate(data)
      {:ok, _eof_or_error} -> {:error, :unavailable}
      {:error, :enoent} -> {:error, :not_ready}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc """
  Validate raw file contents as a token: surrounding whitespace is
  trimmed, and the result must start with `"SP:"`, be at most 127 bytes,
  and hold only printable ASCII.
  """
  @spec validate(binary()) :: {:ok, String.t()} | {:error, :unavailable}
  def validate(data) when is_binary(data) do
    token = String.trim(data)

    if byte_size(token) in 4..@max_bytes//1 and match?("SP:" <> _, token) and
         printable_ascii?(token) do
      {:ok, token}
    else
      {:error, :unavailable}
    end
  end

  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(<<c, rest::binary>>) when c in 0x21..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(_), do: false
end
