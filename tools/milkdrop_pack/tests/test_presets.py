import unittest

from milkpack import presets


def milk(warp=(), comp=()):
    lines = ["[preset00]", "MILKDROP_PRESET_VERSION=201", "PSVERSION=2"]
    lines += [f"warp_{i}=`{line}" for i, line in enumerate(warp, 1)]
    lines += [f"comp_{i}=`{line}" for i, line in enumerate(comp, 1)]
    return "\n".join(lines).encode("latin-1")


class StageCodeTest(unittest.TestCase):
    def test_lines_in_numeric_order_without_backticks(self):
        data = b"warp_1=`a\nwarp_10=`j\nwarp_2=`b\n" + b"".join(f"warp_{i}=`{i}\n".encode() for i in range(3, 10))
        self.assertEqual(presets.shader_code(data)["warp"].split("\n")[:3], ["a", "b", "3"])
        self.assertEqual(presets.shader_code(data)["warp"].split("\n")[-1], "j")

    def test_stops_at_a_gap(self):
        self.assertEqual(presets.shader_code(b"comp_1=`x\ncomp_3=`z\n")["comp"], "x")


class TexturesTest(unittest.TestCase):
    def test_declared_only_is_referenced_not_sampled(self):
        ref, sampled, rand = presets.preset_textures(milk(warp=[
            "sampler sampler_worms;", "float4 texsize_worms;", "shader_body {", "ret = tex2D(sampler_main, uv).xyz;", "}"]))
        self.assertEqual(ref, {"worms"})
        self.assertEqual(sampled, set())
        self.assertFalse(rand)

    def test_sampled_with_prefix_peeled(self):
        ref, sampled, _ = presets.preset_textures(milk(comp=[
            "sampler sampler_fw_clouds;", "shader_body {", "ret = tex2D(sampler_fw_clouds, uv).xyz;", "}"]))
        self.assertEqual(ref, {"clouds"})
        self.assertEqual(sampled, {"clouds"})

    def test_texsize_use_counts_as_sampled(self):
        _, sampled, _ = presets.preset_textures(milk(warp=["ret = uv.x * texsize_seaweed.x;"]))
        self.assertEqual(sampled, {"seaweed"})

    def test_comments_are_ignored(self):
        ref, sampled, _ = presets.preset_textures(milk(warp=[
            "// ret = tex2D(sampler_rose, uv);", "/* tex2D(sampler_skull, uv)", "*/ ret = 0;"]))
        self.assertEqual(ref, set())
        self.assertEqual(sampled, set())

    def test_define_alias_resolves_to_its_target(self):
        ref, sampled, _ = presets.preset_textures(milk(comp=[
            "#define sampler_pic sampler_prayerwheel", "sampler sampler_pic;",
            "shader_body {", "ret = tex2D(sampler_pic, uv).xyz;", "}"]))
        self.assertEqual(sampled, {"prayerwheel"})
        self.assertIn("pic", ref)  # projectM still tries to load the alias name

    def test_builtins_rand_and_state_are_not_user_textures(self):
        ref, sampled, rand = presets.preset_textures(milk(comp=[
            "ret = tex2D(sampler_pw_main, uv) + tex2D(sampler_blur1, uv) + tex3D(sampler_noisevol_hq, x);",
            "ret += tex2D(sampler_rand00, uv) + tex2D(sampler_rand02_smalltiled, uv);",
            "sampler_state x;"]))
        self.assertEqual(ref, set())
        self.assertEqual(sampled, set())
        self.assertTrue(rand)

    def test_the_portal1_preset_shape(self):
        _, sampled, rand = presets.preset_textures(milk(
            warp=["sampler sampler_portal1;", "sampler sampler_fire_dis4;", "sampler sampler_fire_alpha5;",
                  "shader_body {", "ret1 = tex2D(sampler_portal1, float2(uv.x, uv.y)).xyz;",
                  "float3 fire = tex2D(sampler_fire_dis4, uv).xyz;", "}"],
            comp=["sampler sampler_rand00;", "shader_body {", "ret = tex2D(sampler_rand00, uv);", "}"]))
        self.assertEqual(sampled, {"portal1", "fire_dis4"})
        self.assertTrue(rand)


if __name__ == "__main__":
    unittest.main()
