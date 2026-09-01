# Holepunch Corestore native addon

Place a locally built `corestore.node` (or Bare addon) at
`tool/bare/addons/corestore.node`.

- `kHolepunchCorestoreAddonLinked` stays **false** until that file is
  linked into the app bundle for every shipping OS.
- Production must not fetch a remote `.node`.
- The worklet may `require('corestore')` when the JS module is installed
  next to the harness. That is a memory-or-JS fallback, not this addon.
