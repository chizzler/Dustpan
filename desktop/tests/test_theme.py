import pathlib
import tempfile
import unittest

from dustpan.theme import Palette, contrast, load, mix, stylesheet, text_on, variables

# Omarchy's Catppuccin Latte, cut down to what Dustpan reads.
LATTE = """\
mode = "light"
accent = "#1e66f5"
background = "#eff1f5"
foreground = "#4c4f69"
red = "#d20f39"
yellow = "#df8e1d"
orange = "#d84e2b"
green = "#40a02b"
blue = "#1E66F5"
hyprland_active_border = "rgba(e15a48ee) rgba(f0b45aee) 45deg"
"""


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.folder.name) / "colors.toml"

    def tearDown(self):
        self.folder.cleanup()

    def load(self, text):
        self.path.write_text(text)
        return load(self.path)

    def test_keeps_hex_colours_in_lower_case(self):
        palette = self.load(LATTE)
        self.assertEqual(palette.mode, "light")
        self.assertEqual(palette.colors["blue"], "#1e66f5")
        self.assertNotIn("hyprland_active_border", palette.colors)

    def test_no_palette_without_a_usable_file(self):
        self.assertIsNone(load(self.path))
        self.assertIsNone(self.load("background = "))
        self.assertIsNone(self.load(LATTE.replace('green = "#40a02b"\n', "")))
        self.assertIsNone(self.load(LATTE.replace('"#40a02b"', '"green"')))

    def test_mode_without_the_key(self):
        dark = LATTE.replace('mode = "light"\n', "").replace("#eff1f5", "#1e1e2e")
        self.assertEqual(self.load(dark).mode, "dark")
        self.assertEqual(self.load(dark.replace("#1e1e2e", "#eff1f5")).mode, "light")
        self.assertEqual(self.load('theme_type = "light"\n' + dark).mode, "light")
        (self.path.parent / "light.mode").touch()
        self.assertEqual(self.load(dark).mode, "light")


class ColourTest(unittest.TestCase):
    def test_mix(self):
        self.assertEqual(mix("#000000", "#ffffff", 0.5), "#808080")
        self.assertEqual(mix("#102030", "#ffffff", 0), "#102030")

    def test_contrast(self):
        self.assertAlmostEqual(contrast("#000000", "#ffffff"), 21)
        self.assertAlmostEqual(contrast("#777777", "#777777"), 1)

    def test_text_on_picks_the_clearer_of_background_and_foreground(self):
        palette = Palette("dark", {"background": "#1a1b26", "foreground": "#c0caf5"})
        self.assertEqual(text_on("#7aa2f7", palette), "#1a1b26")
        self.assertEqual(text_on("#3d59a1", palette), "#c0caf5")


class StylesheetTest(unittest.TestCase):
    COLORS = {"background": "#1a1b26", "foreground": "#c0caf5", "accent": "#7aa2f7", "red": "#f7768e",
              "yellow": "#e0af68", "orange": "#ff9e64", "green": "#9ece6a", "blue": "#7aa2f7"}

    def test_dark_surfaces_lean_towards_the_foreground(self):
        values = variables(Palette("dark", self.COLORS))
        self.assertEqual(values["window-bg-color"], "#1a1b26")
        self.assertEqual(values["popover-bg-color"], mix("#1a1b26", "#c0caf5", 0.08))
        self.assertEqual(values["accent-fg-color"], "#1a1b26")

    def test_light_cards_lift_towards_white(self):
        values = variables(Palette("light", self.COLORS | {"background": "#eff1f5"}))
        self.assertEqual(values["card-bg-color"], mix("#eff1f5", "#ffffff", 0.6))

    def test_dustpan_colours(self):
        values = variables(Palette("dark", self.COLORS))
        self.assertEqual([values[f"dustpan-{name}"] for name in ("p1", "p2", "p3", "overdue", "today")],
                         ["#f7768e", "#ff9e64", "#7aa2f7", "#f7768e", "#9ece6a"])
        without_orange = {k: v for k, v in self.COLORS.items() if k != "orange"}
        self.assertEqual(variables(Palette("dark", without_orange))["dustpan-p2"], "#e0af68")

    def test_stylesheet_sets_variables_on_root(self):
        css = stylesheet(Palette("dark", self.COLORS))
        self.assertTrue(css.startswith(":root {\n"))
        self.assertIn("  --accent-bg-color: #7aa2f7;\n", css)
