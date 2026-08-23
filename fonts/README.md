# Bundled typefaces

Orbits ships these families in the APK/bundle. Themes must not download fonts
at runtime (no `google_fonts`, no `fonts.googleapis.com` / `fonts.gstatic.com`).

Files are Latin + Cyrillic subsets of the upstream sources so Russian UI
glyphs stay in-app. Instrument Serif has no Cyrillic; unused classic themes
that named it migrate to Inter.

| Family (pubspec `family:`) | Files | Source |
| --- | --- | --- |
| Manrope | `Manrope-Variable.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/manrope` |
| Inter | `Inter-Variable.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/inter` |
| JetBrainsMono | `JetBrainsMono-Variable.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/jetbrainsmono` |
| CormorantGaramond | `CormorantGaramond-Variable.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/cormorantgaramond` |
| NotoSerif | `NotoSerif-Variable.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/notoserif` |
| InstrumentSerif | `InstrumentSerif-Regular.ttf` | [google/fonts](https://github.com/google/fonts) `ofl/instrumentserif` |
| Geist | Regular, SemiBold | [vercel/geist-font](https://github.com/vercel/geist-font) `fonts/Geist/ttf/` |

SIL Open Font License 1.1: `OFL.txt` (Google Fonts families) and
`LICENSE-Geist.txt` (Vercel Geist).
