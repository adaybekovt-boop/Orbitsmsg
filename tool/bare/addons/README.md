# Holepunch Corestore native addon

Place a locally built `corestore.node` (or Bare addon) at
`tool/bare/addons/corestore.node`.

- `kHolepunchCorestoreAddonLinked` stays **false** until that file is
  linked into the app bundle for every shipping OS.
- Production must not fetch a remote `.node`.
- On Node, the worklet may `require('corestore')` when that JS module is
  installed next to the harness (memory fallback if missing). That is
  not this addon.
- On Bare, `useCorestoreIfPresent` must **not** `require('corestore')`.
  Node's addon hangs Bare 1.31 instead of throwing. Wait for a Bare
  `.bare` addon in this slot.
