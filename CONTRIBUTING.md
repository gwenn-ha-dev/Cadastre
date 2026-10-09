# Contributing to Cadastre

Thanks for taking the time. This project follows the gwenn-ha-dev project
charter — the short version is below.

## Before you start

- Open an issue first for anything beyond a typo fix.
- One concern per pull request.

## Working on it

```sh
make build     # release build, warnings are errors
make test      # test suite
make lint      # charter compliance — must pass
./outils/verify.sh   # ground truth on real APFS files: clones, hard links, du
```

`make test` runs the unit tests on synthetic trees. `outils/verify.sh` builds
real files in a temporary folder on an APFS volume and checks the figures the
filesystem itself reports; run it after touching the walker or the accounting.

## Conventions

- **Language.** Identifiers, commit messages and `README.md` are in English;
  comments may be in English or French. `README.fr.md` carries the French
  version and must stay in sync.
- **Commits.** `<Scope>: <what changes>`, imperative, 72 characters max on the
  first line. Example: `Sidebar: combine facet rows with cmd-click`.
- **Branches.** `feat/…`, `fix/…`, `docs/…`. Never commit directly to `main`.
- **Strings.** No user-visible string is hard-coded. Everything goes through
  `Resources/Localizable.xcstrings`, in both `en` and `fr`. `make lint` fails
  if a key is missing in either language.
- **Dependencies.** Default is none. Adding one requires a justification in the
  README's *Dependencies* section.
- **Build artefacts** are never committed.

## Releasing

1. Update `CHANGELOG.md`.
2. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in
   `Resources/Info.plist`.
3. Tag `v<major>.<minor>.<patch>`.
