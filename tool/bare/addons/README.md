# Holepunch Corestore native addon

Place a locally built `corestore.node` at
`tool/bare/addons/corestore.node`, or a Bare addon at
`tool/bare/addons/corestore.bare`, or copy one with
`tool/bare/addons/vendor-corestore.sh <path>` (local file only).

- `kHolepunchCorestoreAddonLinked` stays **false** until that file is
  linked into the app bundle for every shipping OS.
- Production must not fetch a remote `.node` or `.bare`.
- On Node, the worklet may `require('corestore')` when that JS module is
  installed next to the harness (memory fallback if missing). That is
  not this addon.
- On Bare, `useCorestoreIfPresent` must **not** `require('corestore')`.
  Node's addon hangs Bare 1.31 instead of throwing. If a local `.bare`
  file is in `kCorestoreBareAddonSlot`, next to the worklet / Bare
  binary, or `ORBITS_CORESTORE_ADDON`, the worklet calls `Bare.Addon.load`
  on that path only and maps the result through `corestoreCtorFromAddon`.
  A constructor binds Corestore; anything else → encrypted-envelope
  JSONL (`backend = 'fs'`). CMake/Gradle/podspec copy the local sidecar
  into the app bundle when the file exists. That still does not flip
  `kHolepunchCorestoreAddonLinked`.
