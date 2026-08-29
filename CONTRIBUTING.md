# Contributing

Thanks for wanting to help. Keep it simple.

## Pull requests

Work on a **new branch** off `main`, then open a **pull request** into `main`. That is the normal GitHub workflow — not overkill.

```bash
git checkout main
git pull
git checkout -b your-change
# … commit …
git push -u origin your-change
```

Then open a PR against `main`. Direct commits to `main` are for the maintainer.

Please:

- One logical change per PR when you can.
- Do not commit generated files (`ProxBuddy.xcodeproj/`, `*.dylib`, `Python.xcframework/`, the Iceman script trees under `ProxBuddy/Resources/`). Those come from `./build_pm3_ios.sh` and `xcodegen`. See [AGENTS.md](AGENTS.md) for the full list.
- If you add a dependency, it must be GPL-compatible and listed in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## Build

Follow [README.md](README.md). Order matters: `./build_pm3_ios.sh` **before** `xcodegen`.

Unit tests (no hardware) live in `ProxBuddyTests`. If you change parsers or command plumbing, add or update a test there.

## Code

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`. Do not add `@unchecked Sendable` or `nonisolated(unsafe)` unless there is no other way — and say why in the PR.
- Deployment target is iOS 26.0. Do not change it unless the PR is *about* that.
- Fixes that belong in the Iceman client go in `patches/`, not in copied `Resources/` files (those get overwritten on the next build).

By contributing you agree your changes are licensed under **GPL-3.0**, same as the rest of the project.
