# Release checklist

After publishing a `v*` GitHub Release:

1. Confirm `https://github.com/adaybekovt-boop/tkmessenger/releases/latest`
   redirects to the tag you just published (CI on the tag job also checks this).
2. Confirm these URLs 302 to the new assets (do **not** pin a version in
   landing-page HTML):
   - `…/releases/latest/download/orbits-windows-x64.exe`
   - `…/releases/latest/download/orbits-android-universal.apk`
3. Landing (`orbits-eeo.pages.dev`, **out of this repo**) must use the
   `latest/download` paths above. Versioned paths such as `…/download/v8.0.2/…`
   are how the site shipped a stale build after 9.0.x fixes.
4. Do not paste `releases/download/${{ github.ref_name }}` into the public
   website. Those links are fine *inside* a specific Release notes body.

In-repo README already uses `latest/download`. Keep it that way.
