# TSM default theme — resolved palette

GoblinMind's UI matches TSM's look using these exact colors, resolved
2026-11-11 from `LibTSMApp/Source/Service/ThemeColorSets.lua` in the
installed TSM v4.15.

## How TSM builds colors

`ColorRamp(hue, chroma)` → `GetRGBA(step)` = `OKLCH.ToRGB(step/100, chroma, hue)`.
Semantic tokens map to (ramp, step) pairs per `TOKEN_RAMP_STEP_MAP`.

Default theme ramps:

| Ramp | Hue | Chroma |
|---|---|---|
| NEUTRAL (surfaces, text) | 196.9 | 0.008 |
| PRIMARY | 197.0 | 0.007 |
| SECONDARY | 253.0 | 0.022 |
| ACCENT (shared) | 94.2 | 0.168 |
| ERROR (shared) | 28.7 | 0.232 |
| POSITIVE (shared) | 151.5 | 0.201 |
| WARNING (shared) | 62.6 | 0.175 |

## Resolved tokens (sRGB hex)

| Token | Hex | GoblinMind `GM.C` key |
|---|---|---|
| surface/main | `#0e1313` | `surface` |
| surface/variant | `#363c3c` | `surfaceVariant` |
| container/lowest | `#090e0e` | `contLowest` |
| container/low | `#161c1c` | `contLow` |
| container/medium | `#1d2323` | `contMedium` |
| container/high | `#292f2f` | `contHigh` |
| container/highest | `#313737` | `contHighest` |
| outline/main | `#99a0a0` | `outline` |
| outline/variant | `#434949` | `outlineVar` |
| on/surface | `#ecf4f3` | `text` |
| on/surface/low | `#b8bfbf` | `textDim` |
| primary/main | `#b9bfbf` | `primary` |
| secondary/main | `#77818d` | `secondary` |
| accent/main | `#e1ba00` | `accent` |
| accent/variant | `#654000` | `accentDark` |
| error/main | `#fd392e` | `err` |
| positive/main | `#08d36b` | `pos` |
| warning/main | `#ff9707` | `warn` |

## Typography

TSM uses Montserrat — shipped in
`Interface\Addons\TradeSkillMaster\Media\` (Regular, Medium,
SemiBold, ExtraBold, Italic) plus Roboto. GoblinMind references the
same files by path; TSM is a hard dependency so they're always present.
Money style: gold amount in `accent`, silver/copper in `textDim`
("12g 34s 56c", no icons).

## Usage notes

- Window bg = `contLow`, list bg = `contLowest`, row alt = `contLow`,
  header = `contHigh`, borders = `outlineVar` (1px), hover = `outline`.
- Primary CTA = `accent` fill + `contLowest` text; secondary = `contHigh`.
- `pos`/`err`/`warn` for deltas, verdicts, staleness warnings.
