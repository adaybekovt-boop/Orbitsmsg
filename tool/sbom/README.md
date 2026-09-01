# In-tree pin list (not a signed release SBOM)

`ORBITS.sbom.json` is generated from `BUNDLE.manifest` and `BARE.manifest`.
It is a CI pin list, not a signed CycloneDX attestation and not proof that
Bare binaries ship in the app bundle.

```bash
python3 tool/sbom/generate.py
python3 tool/sbom/generate.py --check
```

Dart/Flutter must never fetch the listed Bare tarballs or worklet JS.
