defmodule UniversalProxy.MilkDrop.ImportPlanTest do
  use ExUnit.Case, async: true

  import UniversalProxy.MilkDropUploadFixtures

  alias UniversalProxy.MilkDrop.ImportPlan

  defp sha(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp statuses(results), do: Enum.map(results, &{&1.entry || &1.upload, &1.status})

  describe "single .milk uploads" do
    test "a new preset is added under its normalised name with its sha256" do
      data = milk()

      assert [result] = ImportPlan.plan([{"My  Preset.MILK", {:binary, data}}])

      assert result == %{
               upload: "My  Preset.MILK",
               entry: nil,
               kind: :preset,
               name: "My Preset.milk",
               id: "user/My Preset.milk",
               status: :added,
               replaces: nil,
               sha256: sha(data),
               size: byte_size(data),
               warnings: [],
               data: data
             }
    end

    test "replaced vs unchanged against installed presets, ignoring case" do
      data = milk()
      existing = %{presets: %{"Foo.milk" => sha(data), "Bar.milk" => sha("old")}}

      assert [foo, bar] =
               ImportPlan.plan(
                 [{"foo.milk", {:binary, data}}, {"bar.milk", {:binary, data}}],
                 existing
               )

      assert %{status: :unchanged, name: "Foo.milk", id: "user/Foo.milk", data: nil} = foo
      assert %{status: :replaced, name: "bar.milk", replaces: "Bar.milk", data: ^data} = bar
    end

    test "invalid names, content and file types are rejected" do
      results =
        ImportPlan.plan([
          {"bad?.milk", {:binary, milk()}},
          {"binary.milk", {:binary, <<0, 1, 2>>}},
          {"notes.txt", {:binary, "hello"}},
          {"big.milk", {:binary, String.duplicate("a=1\n", 70_000)}}
        ])

      assert statuses(results) == [
               {"bad?.milk", {:rejected, :invalid_name}},
               {"binary.milk", {:rejected, :nul_byte}},
               {"notes.txt", {:rejected, :unsupported_file}},
               {"big.milk", {:rejected, :too_large}}
             ]
    end

    test "a later upload with the same name in one plan is a duplicate" do
      results =
        ImportPlan.plan([{"a.milk", {:binary, milk()}}, {"A.MILK", {:binary, milk("x=1")}}])

      assert statuses(results) == [{"a.milk", :added}, {"A.MILK", {:rejected, :duplicate_name}}]
    end

    test "a rejected upload doesn't claim its name" do
      results = ImportPlan.plan([{"a.milk", {:binary, "nothing"}}, {"a.milk", {:binary, milk()}}])
      assert statuses(results) == [{"a.milk", {:rejected, :no_values}}, {"a.milk", :added}]
    end

    @tag :tmp_dir
    test "reads uploads from paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "upload-1")
      File.write!(path, milk())
      assert [%{status: :added, data: data}] = ImportPlan.plan([{"a.milk", path}])
      assert data == milk()

      assert [%{status: {:rejected, {:io, :enoent}}}] =
               ImportPlan.plan([{"a.milk", Path.join(tmp_dir, "missing")}])

      assert [%{status: {:rejected, :not_regular_file}}] = ImportPlan.plan([{"a.milk", tmp_dir}])
    end
  end

  describe "zip uploads" do
    test "flattens folders, skips junk and directories, ignores other files" do
      bin =
        zip([
          [name: "pack/"],
          [name: "pack/Deep/Folder/One.milk", data: milk(), method: :deflate],
          [name: "pack/textures/Stars.PNG", data: png(64, 64)],
          [name: "pack/README.txt", data: "hi"],
          [name: "__MACOSX/pack/._One.milk", data: "junk"],
          [name: "pack/.DS_Store", data: "junk"],
          [name: "pack/._Two.milk", data: "junk"],
          [name: "pack/Thumbs.db", data: "junk"]
        ])

      results = ImportPlan.plan([{"pack.zip", {:binary, bin}}])

      assert [
               %{
                 entry: "pack/Deep/Folder/One.milk",
                 name: "One.milk",
                 id: "user/One.milk",
                 status: :added
               },
               %{
                 entry: "pack/textures/Stars.PNG",
                 kind: :texture,
                 name: "Stars.png",
                 id: nil,
                 status: :added
               },
               %{entry: "pack/README.txt", kind: :other, status: :ignored, data: nil}
             ] = results

      assert Enum.all?(results, &(&1.upload == "pack.zip"))
    end

    test "a high_frequency/ folder does not reach the pack's id space" do
      bin = zip([[name: "high_frequency/x.milk", data: milk()]])
      assert [%{id: "user/x.milk", status: :added}] = ImportPlan.plan([{"p.zip", {:binary, bin}}])
    end

    test "basename collisions after flattening: the first wins" do
      bin =
        zip([
          [name: "a/x.milk", data: milk()],
          [name: "b/X.milk", data: milk("y=2")],
          [name: "t/stars.png", data: png(8, 8)],
          [name: "u/Stars.jpg", data: jpeg(8, 8)]
        ])

      assert statuses(ImportPlan.plan([{"p.zip", {:binary, bin}}])) == [
               {"a/x.milk", :added},
               {"b/X.milk", {:rejected, :duplicate_name}},
               {"t/stars.png", :added},
               {"u/Stars.jpg", {:rejected, :duplicate_name}}
             ]
    end

    test "per-entry rejections keep the rest of the archive" do
      bin =
        zip([
          [name: "ok.milk", data: milk()],
          [name: "bad?.milk", data: milk()],
          [name: "empty.milk", data: "[preset00]\n"],
          [name: "huge.png", data: png(4096, 4096)],
          [name: "main.png", data: png(8, 8)],
          [name: "fake.jpg", data: png(8, 8)]
        ])

      assert statuses(ImportPlan.plan([{"p.zip", {:binary, bin}}])) == [
               {"ok.milk", :added},
               {"bad?.milk", {:rejected, :invalid_name}},
               {"empty.milk", {:rejected, :no_values}},
               {"huge.png", {:rejected, {:dimensions, 4096, 4096}}},
               {"main.png", {:rejected, :reserved_name}},
               {"fake.jpg", {:rejected, :bad_magic}}
             ]
    end

    test "declared sizes over the per-type cap are rejected without inflating" do
      # The stream is garbage: inflating it would reject the whole archive.
      bin =
        zip([
          [
            name: "a.milk",
            method: :deflate,
            compressed: :binary.copy(<<0xFF>>, 2_000),
            usize: 300_000
          ],
          [name: "b.milk", data: milk()]
        ])

      assert statuses(ImportPlan.plan([{"p.zip", {:binary, bin}}])) == [
               {"a.milk", {:rejected, :too_large}},
               {"b.milk", :added}
             ]
    end

    test "at most 64 textures per archive" do
      textures = for i <- 1..65, do: [name: "t#{i}.png", data: png(4, 4)]
      results = ImportPlan.plan([{"p.zip", {:binary, zip(textures)}}])

      assert Enum.count(results, &(&1.status == :added)) == 64
      assert List.last(results).status == {:rejected, :too_many_textures}
    end

    test "textures: shadowed by the pack, replaced or unchanged by stem" do
      png = png(8, 8)

      bin =
        zip([
          [name: "stars.png", data: png],
          [name: "Moon.JPG", data: jpeg(8, 8)],
          [name: "sun.png", data: png]
        ])

      existing = %{
        textures: %{"moon.png" => sha("old"), "sun.png" => sha(png)},
        pack_textures: ["Stars.jpg"]
      }

      assert [stars, moon, sun] = ImportPlan.plan([{"p.zip", {:binary, bin}}], existing)
      assert %{status: :added, warnings: [:texture_shadowed], data: ^png} = stars
      assert %{status: :replaced, name: "Moon.jpg", replaces: "moon.png", warnings: []} = moon
      assert %{status: :unchanged, data: nil} = sun
    end

    test "structural failures reject the whole archive in one result" do
      for {bin, reason} <- [
            {zip([[name: "../x.milk", data: milk()]]), {:unsafe_path, "../x.milk"}},
            {zip([[name: "a.milk", data: milk(), local_name: "b.milk"]]),
             {:header_mismatch, "a.milk"}},
            {"not a zip", :not_a_zip}
          ] do
        assert [%{kind: :archive, entry: nil, status: {:rejected, ^reason}}] =
                 ImportPlan.plan([{"p.zip", {:binary, bin}}])
      end
    end

    test "a read failure (CRC, size lie) rejects the whole archive" do
      bin = zip([[name: "a.milk", data: milk()], [name: "b.milk", data: milk(), crc: 1]])

      assert [%{kind: :archive, status: {:rejected, {:crc_mismatch, "b.milk"}}}] =
               ImportPlan.plan([{"p.zip", {:binary, bin}}])
    end

    test "names claimed by one upload are duplicates in the next" do
      bin = zip([[name: "x/a.milk", data: milk()], [name: "b.milk", data: milk()]])

      results = ImportPlan.plan([{"a.milk", {:binary, milk()}}, {"p.zip", {:binary, bin}}])

      assert statuses(results) == [
               {"a.milk", :added},
               {"x/a.milk", {:rejected, :duplicate_name}},
               {"b.milk", :added}
             ]
    end
  end

  test "add/3 threads the plan across calls" do
    plan = ImportPlan.new()
    {[%{status: :added}], plan} = ImportPlan.add(plan, "a.milk", {:binary, milk()})

    assert {[%{status: {:rejected, :duplicate_name}}], _} =
             ImportPlan.add(plan, "a.milk", {:binary, milk()})
  end
end
