defmodule UniversalProxy.FirmwareUpdate.ManifestTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.Manifest

  # Mirrors the example in docs/manifest-format.md.
  defp example_json(overrides \\ %{}) do
    base = %{
      "version" => 1,
      "counter" => 1_789_475_200,
      "signed_at" => "2026-07-15T12:00:00Z",
      "expires_at" => nil,
      "targets" => %{
        "rpi3" => %{
          "asset" => "universal_proxy_rpi3.fw",
          "sha256" => "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
          "size" => 47_185_920
        }
      },
      "deltas" => %{}
    }

    Map.merge(base, overrides)
  end

  defp encode(json), do: JSON.encode!(json)

  describe "parse/1 happy path" do
    test "parses the docs/manifest-format.md example" do
      assert {:ok, manifest} = Manifest.parse(encode(example_json()))

      assert manifest.version == 1
      assert manifest.counter == 1_789_475_200
      assert manifest.signed_at == ~U[2026-07-15 12:00:00Z]
      assert manifest.expires_at == nil
      assert manifest.deltas == %{}

      assert {:ok,
              %{
                asset: "universal_proxy_rpi3.fw",
                sha256: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
                size: 47_185_920
              }} = Manifest.target(manifest, "rpi3")
    end

    test "ignores unknown top-level keys" do
      json = Map.put(example_json(), "future_field", "some_value")

      assert {:ok, %Manifest{}} = Manifest.parse(encode(json))
    end

    test "normalizes uppercase sha256 to lowercase" do
      json =
        put_in(
          example_json(),
          ["targets", "rpi3", "sha256"],
          "9F86D081884C7D659A2FEAA0C55AD015A3BF4F1B2B0B822CD15D6C15B0F00A08"
        )

      assert {:ok, manifest} = Manifest.parse(encode(json))
      assert {:ok, %{sha256: sha}} = Manifest.target(manifest, "rpi3")
      assert sha == "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
    end

    test "stores deltas as-is without validation" do
      json = Map.put(example_json(), "deltas", %{"weird" => [1, 2, "three"]})

      assert {:ok, manifest} = Manifest.parse(encode(json))
      assert manifest.deltas == %{"weird" => [1, 2, "three"]}
    end

    test "expires_at parses when present" do
      json = Map.put(example_json(), "expires_at", "2026-08-01T00:00:00Z")

      assert {:ok, manifest} = Manifest.parse(encode(json))
      assert manifest.expires_at == ~U[2026-08-01 00:00:00Z]
    end
  end

  describe "parse/1 validation failures" do
    test "rejects an unsupported version" do
      json = Map.put(example_json(), "version", 2)

      assert {:error, {:invalid_manifest, {:unsupported_version, 2}}} =
               Manifest.parse(encode(json))
    end

    test "rejects a negative counter" do
      json = Map.put(example_json(), "counter", -1)

      assert {:error, {:invalid_manifest, {:invalid_counter, -1}}} = Manifest.parse(encode(json))
    end

    test "rejects a missing counter" do
      json = Map.delete(example_json(), "counter")

      assert {:error, {:invalid_manifest, :missing_counter}} = Manifest.parse(encode(json))
    end

    test "rejects a malformed signed_at" do
      json = Map.put(example_json(), "signed_at", "not-a-date")

      assert {:error, {:invalid_manifest, {:invalid_signed_at, _reason}}} =
               Manifest.parse(encode(json))
    end

    test "rejects an empty targets map" do
      json = Map.put(example_json(), "targets", %{})

      assert {:error, {:invalid_manifest, :empty_targets}} = Manifest.parse(encode(json))
    end

    test "rejects a target entry missing sha256" do
      json =
        put_in(example_json(), ["targets", "rpi3"], %{
          "asset" => "universal_proxy_rpi3.fw",
          "size" => 47_185_920
        })

      assert {:error, {:invalid_manifest, {:invalid_target_entry, _entry}}} =
               Manifest.parse(encode(json))
    end

    test "rejects a target entry with a bad hex length sha256" do
      json = put_in(example_json(), ["targets", "rpi3", "sha256"], "deadbeef")

      assert {:error, {:invalid_manifest, {:invalid_sha256, "deadbeef"}}} =
               Manifest.parse(encode(json))
    end
  end

  describe "target/2" do
    setup do
      {:ok, manifest} = Manifest.parse(encode(example_json()))
      {:ok, manifest: manifest}
    end

    test "hit returns the target entry", %{manifest: manifest} do
      assert {:ok, %{asset: "universal_proxy_rpi3.fw"}} = Manifest.target(manifest, "rpi3")
    end

    test "miss returns :target_not_found", %{manifest: manifest} do
      assert {:error, {:target_not_found, "rpi5"}} = Manifest.target(manifest, "rpi5")
    end
  end

  describe "check_counter/2" do
    setup do
      {:ok, manifest} = Manifest.parse(encode(example_json(%{"counter" => 100})))
      {:ok, manifest: manifest}
    end

    test "nil stored counter is accepted (first contact)", %{manifest: manifest} do
      assert :ok = Manifest.check_counter(manifest, nil)
    end

    test "empty-string stored counter is accepted (first contact)", %{manifest: manifest} do
      assert :ok = Manifest.check_counter(manifest, "")
    end

    test "equal stored counter is accepted (reinstall)", %{manifest: manifest} do
      assert :ok = Manifest.check_counter(manifest, "100")
    end

    test "greater manifest counter is accepted", %{manifest: manifest} do
      assert :ok = Manifest.check_counter(manifest, "50")
    end

    test "lower manifest counter is rejected as rollback", %{manifest: manifest} do
      assert {:error, {:manifest_rollback, 100, 150}} = Manifest.check_counter(manifest, "150")
    end

    test "garbage stored counter string is treated as absent", %{manifest: manifest} do
      assert :ok = Manifest.check_counter(manifest, "not-a-number")
    end
  end

  describe "check_expiry/3" do
    setup do
      {:ok, manifest} =
        Manifest.parse(encode(example_json(%{"expires_at" => "2026-01-01T00:00:00Z"})))

      {:ok, manifest: manifest}
    end

    test "enforce off with past expiry returns :ok", %{manifest: manifest} do
      now = ~U[2026-07-15 00:00:00Z]
      assert :ok = Manifest.check_expiry(manifest, false, now)
    end

    test "enforce on with nil expires_at returns :ok" do
      {:ok, manifest} = Manifest.parse(encode(example_json(%{"expires_at" => nil})))
      now = ~U[2026-07-15 00:00:00Z]

      assert :ok = Manifest.check_expiry(manifest, true, now)
    end

    test "enforce on with past expiry returns an error", %{manifest: manifest} do
      now = ~U[2026-07-15 00:00:00Z]

      assert {:error, {:manifest_expired, ~U[2026-01-01 00:00:00Z]}} =
               Manifest.check_expiry(manifest, true, now)
    end

    test "enforce on with future expiry returns :ok", %{manifest: manifest} do
      now = ~U[2025-01-01 00:00:00Z]
      assert :ok = Manifest.check_expiry(manifest, true, now)
    end
  end
end
