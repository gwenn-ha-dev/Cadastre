# Cadastre — agent context

## What this is

Disk usage on macOS that tells apart "how big is it" from "what do I get back
if I delete it": an app with a Metal treemap, and the same binary as a
command-line tool. Five metrics per entry (logical, allocated, attributed,
exclusive, retained) that account for APFS clones, hard links, sparse files and
compression. It reads the local filesystem only — no network, no data
collected.

Platform: macOS 14+ (`LSMinimumSystemVersion`, and `minos 14.0` in the binary).
Build system: SwiftPM, Swift 6 language mode (strict concurrency), bundle
assembled by `outils/package.sh`. Bundle ID
`dev.gwennha.Cadastre`. Binary `cadastre`.

## Build and test

```sh
make build   # release, warnings are errors
make test    # unit tests on synthetic trees
make lint    # charter compliance — run before declaring anything done
make package # build/Cadastre.app, signed ad hoc
./outils/verify.sh   # ground truth on real APFS files (needs an APFS volume)
```

Never invoke `swift build` or a build script directly for a deliverable; go
through the `Makefile`. It is the same interface in every project here.

## Invariants — do not break these

- **One binary, two roles.** Launched from the bundle with no argument it opens
  the window; from a terminal it stays a CLI unless `--ui` is given.
  `Cadastre.app/Contents/MacOS/cadastre` must keep working as the full CLI.
- **Never delete, always Trash.** Reclaim moves to the Trash, re-checks every
  guard right before moving, and `⌘Z` puts it back. No `unlink`, no `rm`.
- **Never patch the map after a change; re-measure.** A stale figure is the lie
  this program exists to avoid.
- **Evicted iCloud files are never downloaded** (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`
  before the first `open`).
- **No hard-coded user-visible strings.** Every one goes through `tr("English
  text")` (or `tr("format %@", args…)`), whose key is the English phrase,
  looked up in `Resources/Localizable.xcstrings`. Adding a string means adding
  its entry, with `fr`, in the same change; `testEmbeddedCatalogueHasEveryEntryInFrench`
  and `make lint` catch a missing one. The catalogue is embedded in the binary
  by the `CadastreStrings` target (through the symlink
  `Sources/CadastreStrings/Localizable.xcstrings`), because the same executable
  runs from a terminal with no bundle around it.
- **The language comes from the system** (charter §6): `--lang` and
  `CADASTRE_LANG` exist for the CLI, there is no setting in the app. Numbers
  and dates go through `FormatStyle` / `DateFormatter` with
  `L10n.language.locale`, never a hand-assembled string. The permission prompts
  and the Finder's "Folder" kind are in `Resources/<lang>.lproj/InfoPlist.strings`.
- **No build artefacts committed.** No `.app`, no `build/`, no `.build/`, no `dist/`.
- **Dependencies: none.** Adding one requires documenting it in the README's
  *Dependencies* section.
- **`README.md` and `README.fr.md` stay in sync.** Editing one means editing
  the other.
- **The icon is generated**, never hand-placed: `outils/icone.swift` is the
  source, `make icon` rebuilds `Resources/AppIcon.icns`.
- **The bundle comes from `Resources/`**: `Info.plist` (the version lives
  there), `AppIcon.icns`, every `.lproj`. `outils/package.sh` copies, it does
  not generate.
- **Concurrency**: the UI types are `@MainActor`; `Walker` and `FileWatcher`
  are `@unchecked Sendable` because a lock (`gate`) or the main queue guards
  their state — keep it that way when touching them. AppKit callbacks that
  are not annotated (Quick Look panel, accessibility press, timers) enter the
  main actor with `MainActor.assumeIsolated`.
- Identifiers, commit messages and both READMEs are in **English**; comments may
  be in English or French (charter §2).

## Public identity and releases (charter §12)

- Commit as `gwenn-ha-dev <13298867+gwenn-ha-dev@users.noreply.github.com>` (set
  in this repo's git config) and in UTC: `TZ=UTC git commit …`. No personal name,
  email or `/Users/…` path in tracked files. `../../Charte/outils/identite.sh .` checks.
- A release: `make package && make sign && make dmg && make shots && make release-check`,
  then tag `v<version>` and attach `build/Cadastre-<version>.dmg` — see
  `../../Charte/DISTRIBUTION-AGENT.md`, phase 3. The version is
  `CFBundleShortVersionString` in `Resources/Info.plist`, with a matching
  `## [x.y.z]` section in `CHANGELOG.md`.
- Signing: `outils/package.sh` signs ad hoc, without `--deep` and without
  entitlements — the app needs none beyond the hardened runtime, which
  `make sign` adds with the Developer ID. Nothing is nested in the bundle (the
  string catalogue is compiled into the binary), so there is one piece to sign.
  The hardened runtime does not stop the Metal shader from compiling at launch.
- **Captures never show a real disk.** `make shots` runs `outils/captures.sh`,
  which builds an invented folder with `outils/demo.sh` in `/tmp/cadastre-demo`
  and points the app at it, with `CADASTRE_HOME` there too so the marker
  history stays out of the user's. Never capture `~`, `--disk` or the empty
  state (it lists recent folders). The app is launched by its binary, not
  `open`, so that the environment reaches it; `-AppleLanguages`/`-AppleLocale`
  are filtered out of the options by `main.swift`.

## Layout

```
.github/workflows/ci.yml
Makefile
Package.swift          C target + executable + tests, macOS 14
Resources/             Info.plist, AppIcon.icns, Localizable.xcstrings,
                       en.lproj / fr.lproj (InfoPlist.strings)
Sources/CadastreC/     getattrlistbulk, I/O policies
Sources/CadastreStrings/  the embedded string catalogue
Sources/cadastre/      walker, accounting, index, diff, reclaim, CLI
Sources/cadastre/UI/   treemap (Metal), window, sheets
Tests/CadastreTests/   XCTest on synthetic trees
outils/                icone.swift, package.sh, verify.sh
```

## The charter

The full norm this project follows lives at `../../Charte/CHARTE.md`.
