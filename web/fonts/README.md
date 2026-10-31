# Website fonts

The site hosts its own font assets so typography does not depend on a third-party font request.

- **DM Sans**: variable weights 400–600; Latin and Latin Extended subsets.
- **Source Serif 4**: variable weights 400–600 and optical sizes 8–60; Latin, Latin Extended, Cyrillic, Cyrillic Extended, Greek, and Vietnamese subsets.
- `fonts.css` preserves Google Fonts' Unicode ranges and uses `font-display: swap`; browsers request only the subsets needed by the page.
- Chinese, Japanese and Korean text uses the explicit local fallback stacks in `styles.css`.

WOFF2 files were obtained from the official [Google Fonts CSS API](https://fonts.googleapis.com/css2?family=DM+Sans:wght@400..600&family=Source+Serif+4:opsz,wght@8..60,400..600&display=swap) on 2026-10-31 (DM Sans v17 / Source Serif 4 v15).

Both families use the SIL Open Font License 1.1. License texts are included as `DM-Sans-OFL.txt` and `Source-Serif-4-OFL.txt`, with wording preserved and whitespace normalized; upstream sources are [DM Sans](https://github.com/google/fonts/tree/main/ofl/dmsans) and [Source Serif 4](https://github.com/google/fonts/tree/main/ofl/sourceserif4).
