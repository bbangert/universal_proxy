defmodule UniversalProxy.Audio.PairingTokenTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio
  alias UniversalProxy.Audio.PairingToken

  @moduletag :tmp_dir

  # Shape of a real token: "SP:" + version "0" + 103 base32 chars.
  @token "SP:0" <> String.duplicate("ABCDEFGH34567", 7) <> "ABCDEFGHIJKL"

  defp write!(dir, data), do: File.write!(Path.join(dir, PairingToken.filename()), data)

  test "a missing file is not ready", %{tmp_dir: dir} do
    assert PairingToken.read(dir) == {:error, :not_ready}
    assert PairingToken.read(Path.join(dir, "absent")) == {:error, :not_ready}
  end

  test "returns a valid token, trimmed", %{tmp_dir: dir} do
    assert byte_size(@token) == 107
    write!(dir, @token)
    assert PairingToken.read(dir) == {:ok, @token}

    write!(dir, @token <> "\n")
    assert PairingToken.read(dir) == {:ok, @token}
  end

  test "rejects malformed contents", %{tmp_dir: dir} do
    for bad <- [
          "",
          "\n",
          "SP:",
          "XX:0ABC",
          "sp:0ABC",
          "SP:0AB C",
          "SP:0ABé",
          "SP:0AB\0",
          <<"SP:0", 0xFF>>,
          "SP:" <> String.duplicate("A", 125)
        ] do
      write!(dir, bad)
      assert PairingToken.read(dir) == {:error, :unavailable}, "accepted #{inspect(bad)}"
    end
  end

  test "accepts the 127-byte maximum", %{tmp_dir: dir} do
    token = "SP:" <> String.duplicate("A", 124)
    write!(dir, token)
    assert PairingToken.read(dir) == {:ok, token}

    write!(dir, token <> "\n")
    assert PairingToken.read(dir) == {:ok, token}
  end

  test "rejects a file whose content runs past the read limit", %{tmp_dir: dir} do
    token = "SP:" <> String.duplicate("A", 124)
    write!(dir, token <> "\n\n" <> "garbage")
    assert PairingToken.read(dir) == {:error, :unavailable}

    write!(dir, @token <> String.duplicate(" ", 22) <> "garbage")
    assert PairingToken.read(dir) == {:error, :unavailable}
  end

  test "an unreadable token path is unavailable", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, PairingToken.filename()))
    assert PairingToken.read(dir) == {:error, :unavailable}
  end

  test "Audio.pairing_token/1 is unavailable for an unknown output" do
    assert Audio.pairing_token({"no such output", nil, nil}) == {:error, :unavailable}
  end
end
