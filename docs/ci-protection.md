# CI publication barrier (K02)

GitHub Pages deploy (`pages.yml`) no longer runs on every push to `main`.
It starts only after **Build & Release** succeeds on that commit, and it
refuses to publish unless **Security scans** also has a successful run on
the same SHA.

That is a workflow-level brake. It does **not** replace branch protection.

## Required Settings action

A repository admin must enable this in GitHub (the API is not writable
from this agent — Settings → Branches):

1. Protect `main` (`protected=true`).
2. Require a pull request before merging (no direct push).
3. Require status checks to pass before merging, at least:
   - `Analyze & Test` (job in **Build & Release**)
   - `Gitleaks` and `Semgrep` (jobs in **Security scans**)
4. Do not allow bypassing these checks for administrators if the goal is
   a real publication barrier.

Without those Settings, someone with write access can still push to
`main` or merge a red PR; `pages.yml` will simply not deploy a red
**Build & Release**, which is necessary but not sufficient.

Rulesets were empty at the time of the fifth audit. Fill them in the UI;
do not try to emulate protection with workflow hacks alone.
