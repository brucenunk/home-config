"""Build static, mechanically slanted companions to Bricolage's upright faces."""

import math
import sys
from pathlib import Path

from fontTools.misc.fixedTools import otRound
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables import otTables
from fontTools.ttLib.ttVisitor import TTVisitor
from fontTools.varLib.instancer import instantiateVariableFont


class SlantAnchors(TTVisitor):
    pass


@SlantAnchors.register_attr(otTables.Anchor, "XCoordinate")
def visit(visitor, anchor, attr, value):
    # Combining marks must follow the transformed base and mark outlines.
    anchor.XCoordinate = otRound(value + 0.2 * anchor.YCoordinate)


source, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
weights = {
    200: "ExtraLight",
    300: "Light",
    400: "Regular",
    500: "Medium",
    600: "SemiBold",
    700: "Bold",
    800: "ExtraBold",
}

for weight, label in weights.items():
    font = TTFont(source)
    axes = {axis.axisTag: axis.defaultValue for axis in font["fvar"].axes}
    axes["wght"] = weight
    font = instantiateVariableFont(font, axes, inplace=True)
    SlantAnchors().visit(font["GPOS"])
    glyph_set = font.getGlyphSet()
    outlines = {}
    for name in font.getGlyphOrder():
        # Decompose before transforming, so composite offsets and outlines
        # receive the same shear. Advances stay unchanged.
        recording = DecomposingRecordingPen(glyph_set)
        glyph_set[name].draw(recording)
        pen = TTGlyphPen(None)
        recording.replay(TransformPen(pen, (1, 0, 0.2, 1, 0, 0)))
        outlines[name] = pen.glyph()
    font["glyf"].glyphs = outlines
    for name, glyph in outlines.items():
        glyph.recalcBounds(font["glyf"])
        advance, _ = font["hmtx"][name]
        font["hmtx"][name] = (advance, getattr(glyph, "xMin", 0))

    # Upright TrueType hinting is not valid after shearing the outlines.
    for table in ("fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "DSIG"):
        if table in font:
            del font[table]
    font["post"].italicAngle = -math.degrees(math.atan(0.2))
    font["hhea"].caretSlopeRise = 1000
    font["hhea"].caretSlopeRun = 200
    font["head"].macStyle = 2 | (1 if weight >= 700 else 0)
    font["OS/2"].fsSelection &= ~((1 << 0) | (1 << 5) | (1 << 6) | (1 << 9))
    font["OS/2"].fsSelection |= 1 | ((1 << 5) if weight >= 700 else 0)

    family = "Bricolage Grotesque"
    style = "Italic" if weight == 400 else f"{label} Italic"
    full_name = f"{family} {style}"
    postscript = f"BricolageGrotesque-{label}Italic"
    # Keep copyright and OFL metadata; remove variable-instance names and
    # replace every platform's family/style records with unambiguous names.
    names = font["name"]
    replaced = {1, 2, 3, 4, 6, 16, 17, 21, 22, 25}
    names.names = [n for n in names.names if n.nameID not in replaced and n.nameID < 256]
    values = {
        1: family if weight in (400, 700) else f"{family} {label}",
        2: "Bold Italic" if weight == 700 else "Italic",
        3: f"{postscript};SyntheticOblique;1",
        4: full_name,
        6: postscript,
        16: family,
        17: style,
    }
    for name_id, value in values.items():
        names.setName(value, name_id, 3, 1, 0x409)
        names.setName(value, name_id, 1, 0, 0)
    names.setName("Mechanically slanted companion; not an upstream italic design.", 10, 3, 1, 0x409)
    font.save(destination / f"{postscript}.ttf")
