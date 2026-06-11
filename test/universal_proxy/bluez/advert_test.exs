defmodule UniversalProxy.Bluez.AdvertTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluez.Advert

  describe "address_to_integer/1" do
    test "parses a colon MAC into the MSB-first integer HA expects" do
      assert Advert.address_to_integer("AA:BB:CC:DD:EE:FF") == 0xAABBCCDDEEFF
      assert Advert.address_to_integer("00:00:00:00:00:01") == 1
    end
  end

  describe "reconstruct/1" do
    test "skips when there is no address" do
      assert Advert.reconstruct(%{"RSSI" => -50}) == :skip
    end

    test "carries rssi and address type through" do
      assert {:ok, %{rss: -50, address_type: 1}} =
               Advert.reconstruct(%{
                 "Address" => "11:22:33:44:55:66",
                 "RSSI" => -50,
                 "AddressType" => "random"
               })

      assert {:ok, %{address_type: 0}} =
               Advert.reconstruct(%{"Address" => "11:22:33:44:55:66", "AddressType" => "public"})
    end

    test "reconstructs a manufacturer-data AD element (type 0xFF, little-endian company id)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ManufacturerData" => %{0x004C => <<0x02, 0x15, 0xAA>>}
        })

      # <<len, 0xFF, company_id::little-16, data>>; len = 1+2+3 = 6
      assert raw == <<6, 0xFF, 0x4C, 0x00, 0x02, 0x15, 0xAA>>
    end

    test "reconstructs a 16-bit service-data AD element (type 0x16, e.g. BTHome 0xFCD2)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ServiceData" => %{"0000fcd2-0000-1000-8000-00805f9b34fb" => <<0x40, 0x01, 0x64>>}
        })

      # <<len, 0x16, uuid::little-16, data>>
      assert raw == <<6, 0x16, 0xD2, 0xFC, 0x40, 0x01, 0x64>>
    end

    test "includes complete local name (0x09) and tx power (0x0A)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "Name" => "Govee",
          "TxPower" => -4
        })

      assert raw =~ <<5 + 1, 0x09, "Govee">>
      assert raw =~ <<2, 0x0A, 0xFC>>
    end
  end
end
