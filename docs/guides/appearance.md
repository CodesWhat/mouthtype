# Appearance

Appearance controls how the recording pill and delivery cards look. Open it from the sidebar in the Mouthtype window. A live preview uses the app's real pill drawing over a Light or Dark swatch.

## Pill style

| Style | Notes |
| --- | --- |
| Classic | The default. |
| Hi-Fi | A readout-style pill with its own pixel-art card. |
| Glass | Uses the system glass material. |
| Matrix | A pixel-art look with a padlock sprite. |
| Minimal | The quietest option. |

Delivery cards are drawn for the style you pick and scale with the pill size.

## Pill size

A size change applies the next time the pill shows up.

| Size | What it does |
| --- | --- |
| **Automatic** | Picks Large on screens at least 2000 points wide and Standard otherwise. |
| **Standard** | The normal size. |
| **Large** | Draws everything at twice the Standard size. |

## Fonts and colors

Classic, Glass, Matrix and Minimal get a **Text font** choice. **Override individual fonts** is off by default. Turn it on to set Heading, Body and Readout separately, each with Use base font as its default. **Reset fonts to defaults** clears them.

| Control | Applies to | Choices |
| --- | --- | --- |
| **Text font** | Classic, Glass, Matrix, Minimal | Your font choice. |
| **Override individual fonts** | Classic, Glass, Matrix, Minimal | Heading, Body and Readout separately. Off by default. |
| **Readout colour** | Hi-Fi | Amber, Cool white or Red. |

Hi-Fi's bitmap readouts keep their own artwork.

## Accessibility settings

> [!NOTE]
> Mouthtype follows two macOS accessibility settings, **Reduce Transparency** and **Reduce Motion**.

- Under **Reduce Transparency**, Glass uses a solid background and the preview says so.
- Under **Reduce Motion**, the pill and cards use shorter fades instead of springs and slides, and the menu bar icon holds its middle frame.

## Known quirks

- Glass picks clear or smoked from the wallpaper behind it, so a dark window over a bright wallpaper can lower contrast. Try switching styles.
- The Matrix padlock is low-detail at small sizes. Try Large.
- The Hi-Fi card falls back to the Classic card for text its pixel font can't draw.

See the [known limits](../KNOWN-LIMITS.md).
