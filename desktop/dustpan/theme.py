"""The current Omarchy theme's colours, as a stylesheet for libadwaita. No GTK here.

Omarchy keeps the current theme's palette in colors.toml. The stylesheet sets libadwaita's
colour variables from it, and Dustpan's own priority and due-date colours.
Without a usable palette the app keeps plain Adwaita.
DUSTPAN_THEME names another colors.toml, for development.
"""

import os
import pathlib
import tomllib
from dataclasses import dataclass

# Every theme Omarchy ships has these. A palette without one of them is not used.
REQUIRED = ("background", "foreground", "accent", "red", "yellow", "green", "blue")


@dataclass
class Palette:
    mode: str  # "light" or "dark"
    colors: dict  # name -> "#rrggbb"


def colors_path():
    if path := os.environ.get("DUSTPAN_THEME"):
        return pathlib.Path(path)
    return pathlib.Path.home() / ".local/state/omarchy/current/theme/colors.toml"


def load(path):
    """The palette in path, or None when it's missing or unusable."""
    try:
        values = tomllib.loads(path.read_text())
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        return None
    colors = {key: value.lower() for key, value in values.items() if is_hex(value)}
    if not all(key in colors for key in REQUIRED):
        return None
    return Palette(theme_mode(values, path, colors["background"]), colors)


def theme_mode(values, path, background):
    """As omarchy-theme-color decides it: the mode key, theme_type, a light.mode file, then brightness."""
    mode = values.get("mode") or values.get("theme_type")
    if mode in ("light", "dark"):
        return mode
    if (path.parent / "light.mode").exists():
        return "light"
    return "light" if sum(rgb(background)) > 382 else "dark"


def is_hex(value):
    return (isinstance(value, str) and len(value) == 7 and value[0] == "#"
            and all(c in "0123456789abcdefABCDEF" for c in value[1:]))


def rgb(color):
    return tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))


def mix(start, end, amount):
    """Blend from start towards end, as Omarchy's mix_color does."""
    return "#" + "".join(f"{round(a * (1 - amount) + b * amount):02x}" for a, b in zip(rgb(start), rgb(end)))


def luminance(color):
    """WCAG relative luminance."""
    def linear(c):
        c /= 255
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (linear(c) for c in rgb(color))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    light, dark = sorted((luminance(a), luminance(b)), reverse=True)
    return (light + 0.05) / (dark + 0.05)


def text_on(fill, palette):
    """The theme's background or foreground, whichever reads better on fill."""
    return max(palette.colors["background"], palette.colors["foreground"], key=lambda text: contrast(text, fill))


def variables(palette):
    """CSS variable name -> colour. Surfaces are the background with a little of the foreground mixed in.
    In light themes, cards, dialogs and popovers lift towards white instead, as Adwaita's do."""
    c = palette.colors
    bg, fg = c["background"], c["foreground"]
    light = palette.mode == "light"

    def lift(amount):
        return mix(bg, "#ffffff", 0.6) if light else mix(bg, fg, amount)

    values = {
        "window-bg-color": bg,
        "view-bg-color": bg,
        "headerbar-bg-color": bg,
        "headerbar-backdrop-color": bg,
        "sidebar-bg-color": mix(bg, fg, 0.05),
        "sidebar-backdrop-color": mix(bg, fg, 0.03),
        "secondary-sidebar-bg-color": mix(bg, fg, 0.03),
        "secondary-sidebar-backdrop-color": mix(bg, fg, 0.02),
        "card-bg-color": lift(0.05),
        "thumbnail-bg-color": lift(0.05),
        "dialog-bg-color": lift(0.06),
        "popover-bg-color": lift(0.08),
    }
    for surface in ("window", "view", "headerbar", "sidebar", "secondary-sidebar", "card", "thumbnail", "dialog",
                    "popover"):
        values[f"{surface}-fg-color"] = fg
    for name, key in (("accent", "accent"), ("destructive", "red"), ("error", "red"), ("warning", "yellow"),
                      ("success", "green")):
        values[f"{name}-bg-color"] = c[key]
        values[f"{name}-fg-color"] = text_on(c[key], palette)
    values.update({
        "dustpan-p1": c["red"],
        "dustpan-p2": c.get("orange", c["yellow"]),
        "dustpan-p3": c["blue"],
        "dustpan-overdue": c["red"],
        "dustpan-today": c["green"],
    })
    return values


def stylesheet(palette):
    return ":root {\n" + "".join(f"  --{name}: {color};\n" for name, color in variables(palette).items()) + "}\n"
