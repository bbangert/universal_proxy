import unittest

from milkpack import names


class NormaliseTest(unittest.TestCase):
    def test_whitespace_runs_and_trimming(self):
        self.assertEqual(names.normalise_id("HDFX  New  -  AdamFX .milk"), "HDFX New - AdamFX.milk")
        self.assertEqual(names.normalise_id(" a\tb .milk"), "a b.milk")

    def test_segments_are_normalised_and_folders_kept(self):
        self.assertEqual(names.normalise_id("high_frequency/extreme/ x  y.milk"), "high_frequency/extreme/x y.milk")
        self.assertEqual(names.normalise_id("high_frequency\\a.milk"), "high_frequency/a.milk")

    def test_non_ascii_folds_or_drops(self):
        self.assertEqual(names.normalise_id("Café – naïve.milk"), "Cafe naive.milk")
        self.assertEqual(names.normalise_id("’quote’.milk"), "quote.milk")

    def test_control_characters_become_spaces(self):
        self.assertEqual(names.normalise_id("a\x01b\x7f.milk"), "a b.milk")

    def test_extension_is_lowercased(self):
        self.assertEqual(names.normalise_id("Shout.MILK"), "Shout.milk")

    def test_invalid_names(self):
        for bad in ("x.jpg", ".milk", "  .milk", "a/../b.milk", "a//b.milk", "./a.milk", "/abs.milk"):
            self.assertIsNone(names.normalise_id(bad), bad)
        self.assertIsNone(names.normalise_id("a" * 1100 + ".milk"))

    def test_valid_id_mirrors_the_renderer(self):
        self.assertTrue(names.valid_id("Geiss - Chrome.milk"))
        self.assertTrue(names.valid_id("high_frequency/x.milk"))
        for bad in ("", "/a.milk", "a.mil", "a/./b.milk", "a/../b.milk", "a//b.milk", "tab\t.milk", "é.milk",
                    None, 3):
            self.assertFalse(names.valid_id(bad), repr(bad))


class AssignTest(unittest.TestCase):
    def test_identical_duplicates_are_dropped(self):
        assigned, dropped = names.assign_ids([("a  b.milk", b"x"), ("a b.milk", b"x")])
        self.assertEqual(assigned, [("a  b.milk", "a b.milk")])
        self.assertEqual(dropped, [("a b.milk", "duplicate", "a b.milk")])

    def test_different_content_gets_a_suffix(self):
        assigned, dropped = names.assign_ids([("a b.milk", b"1"), ("a  b.milk", b"2"), ("a   b.milk", b"3")])
        self.assertEqual([pid for _, pid in assigned], ["a b.milk", "a b (2).milk", "a b (3).milk"])
        self.assertEqual(dropped, [])

    def test_invalid_names_are_reported(self):
        assigned, dropped = names.assign_ids([("../x.milk", b"1"), ("ok.milk", b"2")])
        self.assertEqual(assigned, [("ok.milk", "ok.milk")])
        self.assertEqual(dropped, [("../x.milk", "invalid_name", "")])

    def test_tags_follow_the_folders(self):
        self.assertEqual(names.tags_for("a.milk"), [])
        self.assertEqual(names.tags_for("high_frequency/a.milk"), ["high_frequency"])
        self.assertEqual(names.tags_for("high_frequency/extreme/a.milk"), ["high_frequency", "extreme"])


if __name__ == "__main__":
    unittest.main()
