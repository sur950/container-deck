# Brand

Container Deck is presented plainly: the app mark and the name, with no company byline. Names, links, colors and the brand files all live in [`Sources/DeckCore/Config/AppConfig.swift`](../Sources/DeckCore/Config/AppConfig.swift), so a change there reaches the app, the scripts and the release in one place.

## Marks

| File | Use |
|---|---|
| `assets/brand/app-icon-1024.svg`, `.png` | The app icon: three containers on a deck, on a crimson tile. `scripts/bundle.sh` turns the PNG into `AppIcon.icns`. |
| `assets/brand/logo.svg`, `logo-mark.svg`, `logo.png` | The mark on its own, for small places such as the menu bar. |
| `assets/brand/lockup-light.svg`, `lockup-dark.svg` (and `.png`) | The mark and the name on a rounded card with a transparent background. Used at the top of the README and in the website header. |

In the app the mark is drawn in code (`LogoGlyph`, `LogoBadge` and `LogoTile` in `Sources/ContainerDeck/Brand/Brand.swift`), so it stays sharp at every size and follows Light and Dark mode.

After editing an SVG, render the PNG at the size of the existing file with `rsvg-convert`, for example `rsvg-convert -w 1164 lockup-light.svg -o lockup-light.png`.

## Colors

| Role | Light | Dark |
|---|---|---|
| Accent (crimson) | `#B3122E` | `#D3263F` |
| Accent gradient (tiles) | `#D3263F` to `#A10F28` | |
| Text | `#111215` | `#F2F1EE` |
| Secondary text | `#5B5E66` | `#A1A3AB` |
| Window surface | `#F4F3F0` | `#0E0F12` |
| Cards | `#FFFFFF` | `#1B1C20` to `#15161A` |

Crimson is the only accent. Green, amber and red are used for state only: running, warning and error.

## Type

The system font (SF Pro) throughout, Semibold for the product name and headings. Monospaced type (SF Mono) only for identifiers, paths, commands and IP addresses.

## Credit

The project is made by Suresh Konakanchi ([suresh-konakanchi.in](https://suresh-konakanchi.in)). The credit appears in the About window and the website footer, never as a byline under the product name.
