#!/usr/bin/env python3
"""Check the picker stylesheet without needing a display.

Two rules, both of which have already been broken once in this project:

1. Every selector that sets a colour must have a matching `:backdrop` twin
   setting the same colours. A state with no backdrop rule is filled in by
   the desktop theme, which is what made the selected row unreadable in
   0.5.2 -- black text meant for bright green, sitting on theme grey.

2. Every text colour must clear WCAG AA against the background it actually
   sits on. Numbers here are computed, not eyeballed, so a future palette
   change cannot quietly drop a pair below the line.
"""
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from _harness import Results, read_css  # noqa: E402

COLOUR_PROPS = {"color", "background-color", "border-left-color"}

# Text colour against the background it renders on. Kept as an explicit list
# rather than derived from the CSS: the point is to state what the design
# intends, so that a rule change which breaks the intent shows up as a
# failure rather than quietly re-deriving itself into passing.
PAIRS = [
    ("selected row text",       "#FF3355", "#2A0A10", 4.5),
    ("selected row number",     "#C98A00", "#2A0A10", 4.5),
    ("selected pinned text",    "#FFFFFF", "#3A1018", 4.5),
    ("selected pinned number",  "#E0A030", "#3A1018", 4.5),
    ("unselected row text",     "#00CC33", "#000000", 4.5),
    ("unselected pinned text",  "#FF3355", "#000000", 4.5),
    ("pin icon",                "#FF3355", "#000000", 4.5),
    ("search entry text",       "#00FF41", "#001a00", 4.5),
    ("menu item text",          "#00CC33", "#000000", 4.5),
    ("menu item hover text",    "#FFB000", "#3A2A00", 4.5),
    ("selection bar on normal", "#FFB000", "#2A0A10", 3.0),
    ("selection bar on pinned", "#FFB000", "#3A1018", 3.0),
    ("selection bar on list",   "#FFB000", "#000000", 3.0),
]


def parse(css):
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    rules = {}
    for sel, body in re.findall(r"([^{}]+)\{([^}]*)\}", css):
        sel = " ".join(sel.split())
        props = rules.setdefault(sel, {})
        for decl in body.split(";"):
            if ":" in decl:
                key, value = decl.split(":", 1)
                props[key.strip()] = " ".join(value.split())
    return rules


def _channel(value):
    value /= 255.0
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


def luminance(colour):
    colour = colour.lstrip("#")
    r, g, b = (int(colour[i:i + 2], 16) for i in (0, 2, 4))
    return (0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b))


def contrast(foreground, background):
    a, b = luminance(foreground), luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)


def main():
    rules = parse(read_css())
    results = Results("stylesheet")

    for selector in sorted(rules):
        if ":backdrop" in selector:
            continue
        props = rules[selector]
        if not COLOUR_PROPS & props.keys():
            continue
        parts = selector.split()
        twin = (rules.get(" ".join([parts[0] + ":backdrop"] + parts[1:]))
                or rules.get(selector + ":backdrop"))
        if twin is None:
            results.check("%s has a backdrop twin" % selector, False, True)
            continue
        for prop in sorted(COLOUR_PROPS & props.keys()):
            results.check("%s { %s } matches its backdrop twin" % (selector, prop),
                          twin.get(prop), props[prop])

    for name, foreground, background, minimum in PAIRS:
        ratio = contrast(foreground, background)
        results.note("%-24s %s on %s  %5.2f:1 (needs %.1f)"
                     % (name, foreground, background, ratio, minimum))
        results.check("%s clears %.1f:1" % (name, minimum), ratio >= minimum, True)

    results.finish()


if __name__ == "__main__":
    main()
