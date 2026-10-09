# Cadastre — agent context

## What this is

Disk usage on macOS that tells apart "how big is it" from "what do I get back
if I delete it": an app with a Metal treemap, and the same binary as a
command-line tool. Five metrics per entry (logical, allocated, attributed,
exclusive, retained) that account for APFS clones, hard links, sparse files and
compression. It reads the local filesystem only — no network, no data
collected.

Platform: macOS 14+ (`LSMinimumSystemVersion`, and `minos 14.0` in the binary).
Build system: SwiftPM, bundle assembled by `outils/package.sh`. Bundle ID
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
- Identifiers, commit messages and both READMEs are in **English**; comments may
  be in English or French (charter §2).

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
