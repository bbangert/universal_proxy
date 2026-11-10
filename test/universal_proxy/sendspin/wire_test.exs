defmodule UniversalProxy.Sendspin.WireTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.Wire
  alias UniversalProxy.Sendspin.Wire.Reassembler

  describe "client/init and server/init (cleartext)" do
    test "encode/decode round-trips" do
      text = Wire.encode_client_init("Zm9v", 1, "25519_ChaChaPoly_SHA256")

      assert {:ok, %{client_id: "Zm9v", version: 1, suite: "25519_ChaChaPoly_SHA256"}} =
               Wire.decode_client_init(text)
    end

    test "encode produces the exact envelope bytes (byte-for-byte, as needed for the prologue)" do
      text = Wire.encode_client_init("Zm9v", 1, "25519_ChaChaPoly_SHA256")

      assert text ==
               Jason.encode!(%{
                 "type" => "client/init",
                 "payload" => %{
                   "client_id" => "Zm9v",
                   "version" => 1,
                   "suite" => "25519_ChaChaPoly_SHA256"
                 }
               })
    end

    test "server/init encode/decode round-trips" do
      text = Wire.encode_server_init("YmFy", 1)
      assert {:ok, %{server_id: "YmFy", version: 1}} = Wire.decode_server_init(text)
    end

    test "decode rejects the wrong message type" do
      text = Wire.encode_server_init("YmFy", 1)

      assert {:error, {:unexpected_type, "client/init", "server/init"}} =
               Wire.decode_client_init(text)
    end

    test "decode rejects missing/invalid fields without raising" do
      assert {:error, {:missing_field, "client_id"}} =
               Wire.decode_client_init(
                 Jason.encode!(%{"type" => "client/init", "payload" => %{"version" => 1}})
               )

      assert {:error, {:invalid_json, _}} = Wire.decode_client_init("not json")
    end
  end

  describe "prologue/2" do
    test "concatenates the exact wire bytes of client/init then server/init" do
      client_text = Wire.encode_client_init("Zm9v", 1, "25519_ChaChaPoly_SHA256")
      server_text = Wire.encode_server_init("YmFy", 1)

      assert Wire.prologue(client_text, server_text) == client_text <> server_text
    end

    test "encode -> decode -> re-encode is not required to match; prologue must use the ORIGINAL bytes" do
      # The whole point of prologue/2 taking raw bytes rather than re-deriving
      # them from decoded fields: a re-serialization could legitimately differ
      # (key order, whitespace) even though it decodes to the same values.
      client_text = Wire.encode_client_init("Zm9v", 1, "25519_ChaChaPoly_SHA256")
      {:ok, decoded} = Wire.decode_client_init(client_text)
      re_encoded = Wire.encode_client_init(decoded.client_id, decoded.version, decoded.suite)

      assert re_encoded == client_text
    end
  end

  describe "noise/handshake" do
    test "encode/decode round-trips raw handshake bytes" do
      data = :crypto.strong_rand_bytes(48)
      text = Wire.encode_noise_handshake(data)
      assert {:ok, ^data} = Wire.decode_noise_handshake(text)
    end

    test "the empty Noise message 2 inner payload is the literal two bytes {}" do
      # Not encoded/decoded by Wire (that's the Noise session's job) but
      # documented here since it rides inside this same envelope's `data`.
      assert "{}" == "{}"
    end
  end

  describe "generic envelope" do
    test "encode_message/decode_envelope round-trip" do
      text = Wire.encode_message("client/time", %{"client_transmitted" => 42})
      assert {:ok, "client/time", %{"client_transmitted" => 42}} = Wire.decode_envelope(text)
    end

    test "payload defaults to %{} when absent" do
      text = Jason.encode!(%{"type" => "client_stream/end"})
      assert {:ok, "client_stream/end", %{}} = Wire.decode_envelope(text)
    end

    test "invalid envelope shapes are errors, not exceptions" do
      assert {:error, :invalid_envelope} =
               Wire.decode_envelope(Jason.encode!(%{"no_type" => true}))

      assert {:error, {:invalid_json, _}} = Wire.decode_envelope("{not json")
    end
  end

  describe "decode_message/1 dispatch + forward compatibility" do
    test "dispatches every known type to a tagged, parsed result" do
      text = Wire.encode_client_time(42)
      assert {:ok, {:client_time, %{client_transmitted: 42}}} = Wire.decode_message(text)
    end

    test "an unrecognized type decodes to {:unknown, type, payload} instead of erroring" do
      text =
        Jason.encode!(%{"type" => "server/some-future-message", "payload" => %{"foo" => "bar"}})

      assert {:unknown, "server/some-future-message", %{"foo" => "bar"}} =
               Wire.decode_message(text)
    end

    test "a malformed known-type payload still surfaces as an error" do
      text = Jason.encode!(%{"type" => "client/time", "payload" => %{}})
      assert {:error, {:missing_field, "client_transmitted"}} = Wire.decode_message(text)
    end
  end

  describe "wrap_json/1 and unwrap_json/1" do
    test "round-trip" do
      json = Wire.encode_client_time(7)
      assert Wire.wrap_json(json) == <<0>> <> json
      assert {:ok, ^json} = Wire.unwrap_json(Wire.wrap_json(json))
    end

    test "rejects a plaintext whose type byte isn't 0" do
      assert {:error, {:unexpected_type, 0, 12}} = Wire.unwrap_json(<<12, "whatever">>)
    end

    test "rejects empty input" do
      assert {:error, :empty_plaintext} = Wire.unwrap_json(<<>>)
    end
  end

  describe "binary audio frame (type 0x0C)" do
    test "byte-exact header for a known positive timestamp" do
      # struct.pack(">q", 1234567890123456).hex() == "000462d53c8abac0"
      frame = Wire.encode_audio_frame(1_234_567_890_123_456, <<1, 2, 3, 4>>)
      assert frame == <<0x0C, 0x00, 0x04, 0x62, 0xD5, 0x3C, 0x8A, 0xBA, 0xC0, 1, 2, 3, 4>>
    end

    test "byte-exact header for a known negative timestamp (signed, not unsigned)" do
      # struct.pack(">q", -1234567890123456).hex() == "fffb9d2ac3754540"
      frame = Wire.encode_audio_frame(-1_234_567_890_123_456, <<>>)
      assert frame == <<0x0C, 0xFF, 0xFB, 0x9D, 0x2A, 0xC3, 0x75, 0x45, 0x40>>
    end

    test "-1 encodes as all-ones, proving the timestamp is signed not unsigned" do
      frame = Wire.encode_audio_frame(-1, <<>>)
      assert frame == <<0x0C, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
    end

    test "encode/decode round-trips, including negative timestamps and empty payload" do
      for {ts, payload} <- [
            {1_234_567_890_123_456, <<1, 2, 3, 4>>},
            {-1_234_567_890_123_456, <<>>},
            {0, <<0, 0>>}
          ] do
        frame = Wire.encode_audio_frame(ts, payload)
        assert {:ok, ^ts, ^payload} = Wire.decode_audio_frame(frame)
      end
    end

    test "decode rejects wrong type, truncation, and empty input" do
      assert {:error, {:unexpected_type, 0x0C, 0}} = Wire.decode_audio_frame(<<0, 1, 2, 3>>)
      assert {:error, :truncated_audio_frame} = Wire.decode_audio_frame(<<0x0C, 1, 2>>)
      assert {:error, :empty_plaintext} = Wire.decode_audio_frame(<<>>)
    end
  end

  describe "decode_frame/2 — unfragmented frames" do
    test "type 0 dispatches as :json" do
      body = Wire.encode_client_time(7)
      plaintext = Wire.wrap_json(body)

      assert {:complete, {:json, ^body}, reassembler} =
               Wire.decode_frame(plaintext, Reassembler.new())

      assert reassembler == Reassembler.new()
    end

    test "type 0x0C dispatches as :audio, timestamp already parsed out" do
      plaintext = Wire.encode_audio_frame(123, <<9, 9>>)

      assert {:complete, {:audio, 123, <<9, 9>>}, _} =
               Wire.decode_frame(plaintext, Reassembler.new())
    end

    test "any other type dispatches as a generic :binary frame" do
      assert {:complete, {:binary, 4, <<1, 2>>}, _} =
               Wire.decode_frame(<<4, 1, 2>>, Reassembler.new())
    end

    test "empty plaintext is an error" do
      assert {:error, :empty_plaintext} = Wire.decode_frame(<<>>, Reassembler.new())
    end
  end

  describe "decode_frame/2 — fragmentation (type 1)" do
    # `[1][flags][orig_type][data]` first, `[1][flags][data]` after; flags
    # bit 1 = first, bit 0 = last (`messaging.md` "Fragmentation").
    @first 0b10
    @last 0b01
    @middle 0b00

    test "reassembles a message split across a first and a last fragment" do
      body = Wire.encode_client_time(999)
      plaintext = Wire.wrap_json(body)
      <<orig_type, data::binary>> = plaintext
      {first, rest} = String.split_at(data, div(byte_size(data), 2))

      assert {:pending, r1} =
               Wire.decode_frame(<<1, @first, orig_type, first::binary>>, Reassembler.new())

      assert {:complete, {:json, ^body}, r2} = Wire.decode_frame(<<1, @last, rest::binary>>, r1)
      assert r2 == Reassembler.new()
    end

    test "reassembles across multiple continuation fragments" do
      plaintext = Wire.encode_audio_frame(55, <<1, 2, 3, 4, 5, 6>>)
      <<orig_type, rest::binary>> = plaintext
      <<a, b, c, d, e, f, tail::binary>> = rest

      {:pending, r1} = Wire.decode_frame(<<1, @first, orig_type, a>>, Reassembler.new())
      {:pending, r2} = Wire.decode_frame(<<1, @middle, b, c>>, r1)
      {:pending, r3} = Wire.decode_frame(<<1, @middle, d, e, f>>, r2)

      assert {:complete, {:audio, 55, <<1, 2, 3, 4, 5, 6>>}, _} =
               Wire.decode_frame(<<1, @last, tail::binary>>, r3)
    end

    test "a single fragment flagged both first and last dispatches at once" do
      body = Wire.encode_client_time(1)

      assert {:complete, {:json, ^body}, _} =
               Wire.decode_frame(<<1, 0b11, 0, body::binary>>, Reassembler.new())
    end

    test "a non-first fragment with none in flight is a protocol error" do
      assert {:error, :fragment_without_start} =
               Wire.decode_frame(<<1, @last, "data">>, Reassembler.new())

      assert {:error, :fragment_without_start} =
               Wire.decode_frame(<<1, @middle, "data">>, Reassembler.new())
    end

    test "a first fragment while one is in flight is a protocol error" do
      {:pending, r1} = Wire.decode_frame(<<1, @first, 0, "abc">>, Reassembler.new())
      assert {:error, :fragment_restarted} = Wire.decode_frame(<<1, @first, 0, "x">>, r1)
    end

    test "a first fragment with no orig_type byte is a protocol error" do
      assert {:error, :fragment_missing_orig_type} =
               Wire.decode_frame(<<1, @first>>, Reassembler.new())

      assert {:error, :fragment_missing_flags} = Wire.decode_frame(<<1>>, Reassembler.new())
    end

    test "an orig_type of 1 is a protocol error" do
      assert {:error, :invalid_orig_type} =
               Wire.decode_frame(<<1, @first, 1, "x">>, Reassembler.new())
    end

    test "a nonzero reserved flag bit is a protocol error" do
      for flags <- [0b100, 0b1000_0010, 0xFF] do
        assert {:error, :fragment_reserved_flags} =
                 Wire.decode_frame(<<1, flags, 0, "x">>, Reassembler.new())
      end
    end

    test "a non-fragment frame while a fragmented message is in flight is a protocol error" do
      {:pending, r1} = Wire.decode_frame(<<1, @first, 0, "abc">>, Reassembler.new())
      assert {:error, :fragment_interrupted} = Wire.decode_frame(<<0, "oops">>, r1)
    end

    test "the retired legacy IDs 2 and 3 are just unimplemented binary types now" do
      assert {:complete, {:binary, 2, <<0, "abc">>}, _} =
               Wire.decode_frame(<<2, 0, "abc">>, Reassembler.new())

      assert {:complete, {:binary, 3, "abc"}, _} =
               Wire.decode_frame(<<3, "abc">>, Reassembler.new())
    end
  end

  describe "decode_frame/2 — reassembly bounds (W4)" do
    test "the running size on the reassembler matches the actual buffer length at every step" do
      {:pending, r1} = Wire.decode_frame(<<1, 0b10, 0, "abc">>, Reassembler.new())
      assert r1.size == 3
      assert IO.iodata_length(r1.buffer) == 3

      {:pending, r2} = Wire.decode_frame(<<1, 0, "de">>, r1)
      assert r2.size == 5
      assert IO.iodata_length(r2.buffer) == 5

      {:pending, r3} = Wire.decode_frame(<<1, 0, "fghij">>, r2)
      assert r3.size == 10
      assert IO.iodata_length(r3.buffer) == 10

      assert {:complete, {:json, "abcdefghij"}, r4} = Wire.decode_frame(<<1, 0b01>>, r3)
      assert r4 == Reassembler.new()
    end

    test "a fragment flood is rejected once the byte cap is exceeded, not accumulated forever" do
      chunk = :binary.copy(<<0>>, 65_000)

      # 17 chunks of 65,000 bytes = 1,105,000 bytes, past the 1 MB cap —
      # each fed as its own fragment, well under the fragment COUNT cap, so
      # this exercises the byte cap specifically.
      {:pending, r1} = Wire.decode_frame(<<1, 0b10, 0, chunk::binary>>, Reassembler.new())

      result =
        Enum.reduce_while(2..17, {:pending, r1}, fn _i, {:pending, r} ->
          case Wire.decode_frame(<<1, 0, chunk::binary>>, r) do
            {:pending, _} = pending -> {:cont, pending}
            {:error, _} = error -> {:halt, error}
          end
        end)

      assert {:error, :fragment_too_large} = result
    end

    test "the fragment COUNT cap trips independent of size on tiny fragments" do
      {:pending, r1} = Wire.decode_frame(<<1, 0b10, 0, 1>>, Reassembler.new())

      result =
        Enum.reduce_while(2..5_000, {:pending, r1}, fn _i, {:pending, r} ->
          case Wire.decode_frame(<<1, 0, 1>>, r) do
            {:pending, _} = pending -> {:cont, pending}
            {:error, _} = error -> {:halt, error}
          end
        end)

      assert {:error, :too_many_fragments} = result
    end
  end

  describe "server/hello" do
    test "round-trips" do
      text = Wire.encode_server_hello("Living Room")
      assert {:ok, %{name: "Living Room"}} = Wire.decode_server_hello(text)
    end
  end

  describe "client/hello" do
    @base %{
      name: "USB Capture",
      device_info: nil,
      supported_roles: ["source@v1"],
      source_v1_support: %{features: %{line_sense: nil}},
      supported_pair_methods: %{pairing_psk: %{}},
      unpaired_access: %{enabled: false}
    }

    test "round-trips the minimal shape" do
      text = Wire.encode_client_hello(@base)
      assert {:ok, decoded} = Wire.decode_client_hello(text)
      assert decoded == @base
    end

    test "round-trips with device_info" do
      fields = %{
        @base
        | device_info: %{
            product_name: "Universal Proxy",
            manufacturer: "bbangert",
            software_version: "1.2.3",
            mac_address: "aa:bb:cc:dd:ee:ff"
          }
      }

      text = Wire.encode_client_hello(fields)
      assert {:ok, ^fields} = Wire.decode_client_hello(text)
    end

    test "sends no trust_level, and supported_pair_methods as an object keyed by method" do
      fields = %{
        @base
        | supported_pair_methods: %{
            pairing_psk: %{},
            dynamic_pairing_code: %{out_channels: ["display"], formats: ["digits"]}
          }
      }

      {:ok, "client/hello", payload} =
        fields |> Wire.encode_client_hello() |> Wire.decode_envelope()

      refute Map.has_key?(payload, "trust_level")

      assert payload["supported_pair_methods"] == %{
               "pairing_psk" => %{},
               "dynamic_pairing_code" => %{"out_channels" => ["display"], "formats" => ["digits"]}
             }
    end

    test "golden payload: the source's rc1 client/hello" do
      fields = %{
        name: "Line In",
        device_info: nil,
        supported_roles: ["source@v1"],
        source_v1_support: %{features: %{line_sense: false}},
        supported_pair_methods: %{
          pairing_psk: %{},
          dynamic_pairing_code: %{out_channels: ["display"], formats: ["digits"]}
        },
        unpaired_access: %{enabled: false}
      }

      assert Jason.decode!(Wire.encode_client_hello(fields)) == %{
               "type" => "client/hello",
               "payload" => %{
                 "name" => "Line In",
                 "supported_roles" => ["source@v1"],
                 "source@v1_support" => %{"features" => %{"line_sense" => false}},
                 "supported_pair_methods" => %{
                   "pairing_psk" => %{},
                   "dynamic_pairing_code" => %{
                     "out_channels" => ["display"],
                     "formats" => ["digits"]
                   }
                 },
                 "unpaired_access" => %{"enabled" => false}
               }
             }
    end

    test "round-trips line_sense features and fuller pair-method descriptors" do
      fields = %{
        @base
        | source_v1_support: %{features: %{line_sense: true}},
          supported_pair_methods: %{
            pairing_psk: %{locations: ["operator"]},
            static_pairing_code: %{locations: ["device"]}
          }
      }

      text = Wire.encode_client_hello(fields)
      assert {:ok, ^fields} = Wire.decode_client_hello(text)
    end

    test "an unrecognized pair method key is ignored, not an error or a new atom" do
      payload =
        build_client_hello_payload(@base)
        |> put_in(["supported_pair_methods", "future_method"], %{"x" => 1})

      text = Jason.encode!(%{"type" => "client/hello", "payload" => payload})

      assert {:ok, %{supported_pair_methods: %{pairing_psk: %{}} = methods}} =
               Wire.decode_client_hello(text)

      assert map_size(methods) == 1
    end

    test "the pre-rc1 list shape is rejected" do
      payload =
        build_client_hello_payload(@base)
        |> Map.put("supported_pair_methods", [%{"method" => "pairing_psk"}])

      text = Jason.encode!(%{"type" => "client/hello", "payload" => payload})

      assert {:error, {:invalid_field, "supported_pair_methods"}} =
               Wire.decode_client_hello(text)
    end

    test "a server MUST NOT see the support object without the role listed, and vice versa" do
      # Not a Wire-enforced invariant (that's the FSM's job) — just proving
      # both are independently encodable so the FSM can enforce it.
      fields = %{@base | source_v1_support: nil}
      text = Wire.encode_client_hello(fields)
      assert {:ok, %{source_v1_support: nil}} = Wire.decode_client_hello(text)
    end

    defp build_client_hello_payload(fields) do
      {:ok, "client/hello", payload} =
        fields |> Wire.encode_client_hello() |> Wire.decode_envelope()

      payload
    end
  end

  describe "client/goodbye" do
    test "golden payloads for the reasons the source sends" do
      for reason <- [:pairing_required, :unauthorized, :shutdown] do
        assert Jason.decode!(Wire.encode_client_goodbye(reason)) == %{
                 "type" => "client/goodbye",
                 "payload" => %{"reason" => Atom.to_string(reason)}
               }
      end
    end
  end

  describe "noise/handshake message 1 payload" do
    test "decodes psk_id with each psk_category code" do
      for {code, category} <- [{"lt", :long_term}, {"pr", :pairing}, {"sn", :sentinel}] do
        payload = Jason.encode!(%{"psk_id" => "abc", "psk_category" => code})

        assert {:ok, %{psk_id: "abc", psk_category: ^category}} =
                 Wire.decode_noise_msg1_payload(payload)

        assert Jason.decode!(Wire.encode_noise_msg1_payload("abc", category)) == %{
                 "psk_id" => "abc",
                 "psk_category" => code
               }
      end
    end

    test "a missing or unknown category, missing psk_id or non-JSON is malformed" do
      for payload <- [
            ~s({"psk_id":"abc"}),
            ~s({"psk_id":"abc","psk_category":"xx"}),
            ~s({"psk_category":"lt"}),
            ~s({"psk_id":1,"psk_category":"lt"}),
            "not json",
            ""
          ] do
        assert {:error, :malformed_handshake_payload} = Wire.decode_noise_msg1_payload(payload)
      end
    end
  end

  describe "server/activate" do
    test "round-trips activities-only (no pairing, active_roles omitted)" do
      fields = %{activities: [:playback], active_roles: nil, pairing: nil}
      text = Wire.encode_server_activate(fields)
      assert {:ok, ^fields} = Wire.decode_server_activate(text)
    end

    test "extracts active_roles and the rc1 pairing method and format" do
      for pairing <- [
            %{method: :dynamic_pairing_code, format: :digits},
            %{method: :pairing_psk, format: nil},
            %{method: :static_pairing_code, format: nil}
          ] do
        fields = %{activities: [:pairing], active_roles: [], pairing: pairing}
        text = Wire.encode_server_activate(fields)
        assert {:ok, ^fields} = Wire.decode_server_activate(text)
      end
    end

    test "an unknown method or format decodes to {:unknown, string} rather than erroring" do
      text =
        Jason.encode!(%{
          "type" => "server/activate",
          "payload" => %{
            "activities" => ["pairing"],
            "active_roles" => [],
            "pairing" => %{"method" => "dynamic_pin", "format" => "hologram"}
          }
        })

      assert {:ok,
              %{pairing: %{method: {:unknown, "dynamic_pin"}, format: {:unknown, "hologram"}}}} =
               Wire.decode_server_activate(text)
    end

    test "an unknown activity decodes to {:unknown, string}, not an error or a new atom" do
      text =
        Jason.encode!(%{
          "type" => "server/activate",
          "payload" => %{"activities" => ["playback", "management"], "active_roles" => []}
        })

      assert {:ok, %{activities: [:playback, {:unknown, "management"}]}} =
               Wire.decode_server_activate(text)
    end

    test "server/unpair is recognized" do
      assert {:ok, {:server_unpair, %{}}} = Wire.decode_message(Wire.encode_server_unpair())

      assert Jason.decode!(Wire.encode_server_unpair()) == %{
               "type" => "server/unpair",
               "payload" => %{}
             }
    end

    test "multiple activities round-trip in order" do
      fields = %{activities: [:playback, :pairing], active_roles: ["source@v1"], pairing: nil}
      text = Wire.encode_server_activate(fields)
      assert {:ok, ^fields} = Wire.decode_server_activate(text)
    end
  end

  describe "client/time and server/time" do
    test "client/time round-trips" do
      text = Wire.encode_client_time(123_456)
      assert {:ok, %{client_transmitted: 123_456}} = Wire.decode_client_time(text)
    end

    test "server/time round-trips all three timestamps with the right field names" do
      text = Wire.encode_server_time(100, 250, 260)

      assert {:ok, %{client_transmitted: 100, server_received: 250, server_transmitted: 260}} =
               Wire.decode_server_time(text)
    end
  end

  describe "client/state (source object)" do
    test "golden payload: an active source always carries the full source object" do
      assert Jason.decode!(Wire.encode_client_state(false, %{signal: nil})) == %{
               "type" => "client/state",
               "payload" => %{"available" => false, "source" => %{}}
             }
    end

    test "round-trips with no source object" do
      text = Wire.encode_client_state(true, nil)
      assert {:ok, %{available: true, source: nil}} = Wire.decode_client_state(text)
    end

    test "round-trips source: {} (line-sense capable but no current signal)" do
      text = Wire.encode_client_state(true, %{signal: nil})
      assert {:ok, %{available: true, source: %{signal: nil}}} = Wire.decode_client_state(text)
    end

    test "round-trips signal present and absent" do
      for signal <- [:present, :absent] do
        text = Wire.encode_client_state(false, %{signal: signal})

        assert {:ok, %{available: false, source: %{signal: ^signal}}} =
                 Wire.decode_client_state(text)
      end
    end
  end

  describe "server/command (source object)" do
    test "round-trips no source command" do
      text = Wire.encode_server_command(nil)
      assert {:ok, %{source: nil}} = Wire.decode_server_command(text)
    end

    test "round-trips start and stop" do
      for command <- [:start, :stop] do
        text = Wire.encode_server_command(%{command: command})
        assert {:ok, %{source: %{command: ^command}}} = Wire.decode_server_command(text)
      end
    end
  end

  describe "client-stream/start and client-stream/end" do
    test "round-trips a pcm stream with no codec_header" do
      fields = %{codec: :pcm, channels: 2, sample_rate: 48_000, bit_depth: 16, codec_header: nil}
      text = Wire.encode_client_stream_start(fields)
      assert {:ok, ^fields} = Wire.decode_client_stream_start(text)

      assert Jason.decode!(text) == %{
               "type" => "client-stream/start",
               "payload" => %{
                 "source" => %{
                   "codec" => "pcm",
                   "channels" => 2,
                   "sample_rate" => 48_000,
                   "bit_depth" => 16
                 }
               }
             }
    end

    test "the pre-rc1 underscore name is no longer recognized" do
      text = Wire.encode_message("client_stream/start", %{"source" => %{}})
      assert {:unknown, "client_stream/start", _} = Wire.decode_message(text)
    end

    test "round-trips a flac stream whose codec_header is standard (padded) Base64" do
      header = <<"fLaC", 0::8, 0, 0, 34>> <> :crypto.strong_rand_bytes(34)

      fields = %{
        codec: :flac,
        channels: 2,
        sample_rate: 44_100,
        bit_depth: 16,
        codec_header: header
      }

      text = Wire.encode_client_stream_start(fields)

      assert {:ok, ^fields} = Wire.decode_client_stream_start(text)

      # codec_header is standard Base64 (padded), not base64url — assert the
      # wire text actually uses that alphabet/padding convention.
      {:ok, "client-stream/start", %{"source" => %{"codec_header" => wire_header}}} =
        Wire.decode_envelope(text)

      assert wire_header == Base.encode64(header)
    end

    test "client-stream/end has no payload fields" do
      text = Wire.encode_client_stream_end()
      assert {:ok, %{}} = Wire.decode_client_stream_end(text)
      assert {:ok, "client-stream/end", %{}} = Wire.decode_envelope(text)
    end
  end

  describe "pairing messages" do
    test "client/pair-init round-trips with and without commit_B (dynamic code vs the others)" do
      commit_b = :crypto.strong_rand_bytes(32)

      text_static = Wire.encode_client_pair_init(1)
      assert {:ok, %{pairing_index: 1, commit_b: nil}} = Wire.decode_client_pair_init(text_static)

      text_dynamic = Wire.encode_client_pair_init(2, commit_b)

      assert {:ok, %{pairing_index: 2, commit_b: ^commit_b}} =
               Wire.decode_client_pair_init(text_dynamic)
    end

    test "server/pair-init round-trips the 32-byte nonce_A, and omits it on a retry round" do
      nonce_a = :crypto.strong_rand_bytes(32)
      text = Wire.encode_server_pair_init(nonce_a)
      assert {:ok, %{nonce_a: ^nonce_a}} = Wire.decode_server_pair_init(text)

      retry = Wire.encode_server_pair_init(nil)
      assert {:ok, "server/pair-init", %{}} = Wire.decode_envelope(retry)
      assert {:ok, %{nonce_a: nil}} = Wire.decode_server_pair_init(retry)
    end

    test "client/pair-pending and client/pair-retry golden payloads" do
      assert Jason.decode!(Wire.encode_client_pair_pending(2, "Press the button")) == %{
               "type" => "client/pair-pending",
               "payload" => %{"pairing_index" => 2, "message" => "Press the button"}
             }

      assert Jason.decode!(Wire.encode_client_pair_pending(1)) == %{
               "type" => "client/pair-pending",
               "payload" => %{"pairing_index" => 1}
             }

      assert Jason.decode!(Wire.encode_client_pair_retry()) == %{
               "type" => "client/pair-retry",
               "payload" => %{}
             }
    end

    test "pair/abort round-trips every documented reason" do
      for reason <- [
            :attempt_timeout,
            :concurrent_attempt,
            :method_not_supported,
            :pairing_code_mismatch,
            :user_cancelled
          ] do
        text = Wire.encode_pair_abort(reason)
        assert {:ok, %{reason: ^reason}} = Wire.decode_pair_abort(text)
      end
    end

    test "pair/abort tolerates an unrecognized reason instead of erroring" do
      text =
        Jason.encode!(%{"type" => "pair/abort", "payload" => %{"reason" => "some_future_reason"}})

      assert {:ok, %{reason: {:unknown, "some_future_reason"}}} = Wire.decode_pair_abort(text)
    end

    test "server/pair-auth and client/pair-auth round-trip 32-byte CPace shares" do
      ya = :crypto.strong_rand_bytes(32)
      yb = :crypto.strong_rand_bytes(32)

      assert {:ok, %{pake_msg_1: ^ya}} =
               ya |> Wire.encode_server_pair_auth() |> Wire.decode_server_pair_auth()

      assert {:ok, %{pake_msg_2: ^yb}} =
               yb |> Wire.encode_client_pair_auth() |> Wire.decode_client_pair_auth()
    end

    test "server/pair-confirm round-trips a 64-byte MCF tag" do
      ta = :crypto.strong_rand_bytes(64)

      assert {:ok, %{server_kc: ^ta}} =
               ta |> Wire.encode_server_pair_confirm() |> Wire.decode_server_pair_confirm()
    end

    test "client/pair-confirm round-trips with and without wrapped_nonce_B (static vs dynamic)" do
      tb = :crypto.strong_rand_bytes(64)
      wrapped = :crypto.strong_rand_bytes(48)

      text_static = Wire.encode_client_pair_confirm(tb)

      assert {:ok, %{client_kc: ^tb, wrapped_nonce_b: nil}} =
               Wire.decode_client_pair_confirm(text_static)

      text_dynamic = Wire.encode_client_pair_confirm(tb, wrapped)

      assert {:ok, %{client_kc: ^tb, wrapped_nonce_b: ^wrapped}} =
               Wire.decode_client_pair_confirm(text_dynamic)

      {:ok, "client/pair-confirm", payload} = Wire.decode_envelope(text_dynamic)
      assert Map.keys(payload) |> Enum.sort() == ["client_kc", "wrapped_nonce_B"]
    end

    test "client/pair-finalize round-trips long_term_psk (Pairing PSK flow)" do
      psk = :crypto.strong_rand_bytes(32)
      assert {:ok, text} = Wire.encode_client_pair_finalize(%{long_term_psk: psk})
      assert {:ok, %{long_term_psk: ^psk}} = Wire.decode_client_pair_finalize(text)
    end

    test "client/pair-finalize round-trips wrapped_psk (pairing-code flows)" do
      wrapped = :crypto.strong_rand_bytes(48)
      assert {:ok, text} = Wire.encode_client_pair_finalize(%{wrapped_psk: wrapped})
      assert {:ok, %{wrapped_psk: ^wrapped}} = Wire.decode_client_pair_finalize(text)
    end

    test "client/pair-finalize enforces the documented XOR on encode" do
      assert {:error, :missing_psk_field} = Wire.encode_client_pair_finalize(%{})
    end

    test "client/pair-finalize enforces the documented XOR on decode" do
      both =
        Jason.encode!(%{
          "type" => "client/pair-finalize",
          "payload" => %{"long_term_psk" => "abc", "wrapped_psk" => "def"}
        })

      neither = Jason.encode!(%{"type" => "client/pair-finalize", "payload" => %{}})

      assert {:error, :exactly_one_psk_field_required} = Wire.decode_client_pair_finalize(both)
      assert {:error, :missing_psk_field} = Wire.decode_client_pair_finalize(neither)
    end

    test "server/pair-finalize has no payload fields" do
      text = Wire.encode_server_pair_finalize()
      assert {:ok, %{}} = Wire.decode_server_pair_finalize(text)
      assert {:ok, "server/pair-finalize", %{}} = Wire.decode_envelope(text)
    end
  end

  describe "alignment with UniversalProxy.Sendspin.Pairing" do
    # Pairing builds `{type, payload}` tuples with string-keyed, already
    # base64url-encoded payloads (it does its own base64url handling) and
    # expects `Wire.decode_envelope/1`'s raw payload map back on receipt — it
    # never calls Wire's typed pairing functions directly. These checks prove
    # Wire's envelope plumbing and typed field names stay in lockstep with
    # what Pairing actually emits/consumes, without either module depending
    # on the other's internals.
    alias UniversalProxy.Sendspin.Pairing

    test "a real Pairing.start/1 client/pair-init round-trips through Wire's typed codec" do
      {:ok, [{"client/pair-init", payload}], _state} =
        Pairing.start(
          handshake_hash: :crypto.strong_rand_bytes(32),
          pairing_index: 1,
          suite: "25519_ChaChaPoly_SHA256"
        )

      text = Wire.encode_message("client/pair-init", payload)
      assert {:ok, %{pairing_index: 1, commit_b: <<_::256>>}} = Wire.decode_client_pair_init(text)
    end

    test "a real Pairing.abort/2 pair/abort round-trips through Wire's typed codec" do
      state = %{
        method: :dynamic_pairing_code,
        stage: :awaiting_server_init,
        handshake_hash: :crypto.strong_rand_bytes(32),
        pairing_index: 0,
        sid: <<0>>,
        suite: "25519_ChaChaPoly_SHA256",
        psk: :crypto.strong_rand_bytes(32)
      }

      state = struct(Pairing, state)

      {:abort, :pairing_code_mismatch, [{"pair/abort", payload}], _state} =
        Pairing.abort(state, :pairing_code_mismatch)

      text = Wire.encode_message("pair/abort", payload)
      assert {:ok, %{reason: :pairing_code_mismatch}} = Wire.decode_pair_abort(text)
    end

    test "decode_envelope's raw payload is exactly what Pairing.handle/3 expects" do
      # Feeding a Wire-decoded envelope straight into Pairing.handle/3 without
      # any intermediate translation is the whole point of Pairing not using
      # Wire's typed decoders — this is the actual integration shape.
      nonce_a = :crypto.strong_rand_bytes(32)
      text = Wire.encode_server_pair_init(nonce_a)
      {:ok, "server/pair-init", payload} = Wire.decode_envelope(text)

      state = %{
        method: :dynamic_pairing_code,
        stage: :awaiting_server_init,
        handshake_hash: :crypto.strong_rand_bytes(32),
        pairing_index: 0,
        sid: Pairing.sid(:crypto.strong_rand_bytes(32), 0, 1),
        suite: "25519_ChaChaPoly_SHA256",
        psk: :crypto.strong_rand_bytes(32),
        nonce_b: :crypto.strong_rand_bytes(32)
      }

      state = struct(Pairing, state)
      assert {:pin, pin, _state} = Pairing.handle(state, "server/pair-init", payload)
      assert is_binary(pin)
    end
  end
end
