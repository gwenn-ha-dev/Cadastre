# Cadastre

*[Version française](README.fr.md)*

Disk usage measurement for macOS, built around one idea: on APFS,
"how big is it" and "what do I get back if I delete it"
are two different questions, with two different answers.

An app with a map, and the same binary as a command-line tool. Both
speak French and English, depending on the system language.

## Getting started

```
./Scripts/bundle.sh        # produces Cadastre.app
open Cadastre.app
```

Double-click: it suggests a folder — or one of the last ones measured —,
measures it, and displays the map. A folder dropped onto the window or onto
the Dock icon is measured too.

| | |
|---|---|
| `⌘O` | choose a folder · the File menu keeps the last eight |
| `⌘⇧O` | measure this Mac: the Data volume, framed by the container's other volumes |
| `⌘⇧R` | measure the same folder again |
| `⌘⇧L` | follow changes: every write under the folder triggers a background measure |
| `⌘S` | drop a marker, to compare later |
| `⌘R` | the "reclaim space" panel |
| `⌘D` | the "what changed" panel, when a marker is loaded |
| `⌘E` | export the map as PNG |
| `⌘F` | search for a name: anything that doesn't match fades out |
| `⌘1`…`⌘5` | the metric · `⌥⌘1`…`⌥⌘5` the colour |
| double-click · `↩` | go down into a folder · `⌫` or `⌘↑` to go back up, `⌘⇧↑` to the root |
| `←` `→` `↑` `↓` | move from one rectangle to its neighbour · `⇥` to enter the selection |
| `space` | Quick Look the selection; the arrows keep working underneath |
| right-click | open, reveal in Finder, copy path, move to Trash |
| `⌥⌘I` | hide the inspector |
| `⌘.` | stop a scan in progress — the map is shown as is, marked partial |

The Cadastre › Language menu forces French or English, independent of the
system, without relaunching: the window is rebuilt and the folder measured again.

`⌘Z` puts back what just went to the Trash — one entry from the context menu
as well as a whole selection from the "reclaim" panel — and measures again.
Under VoiceOver, the map exposes its first two levels as buttons named by
their size and kind; activating one goes into the folder or reveals the file.

The "compare to" menu in the toolbar lists the markers already dropped on
this folder. After a deletion, the map is **re-measured**, never patched:
every figure shown is a claim about the disk, and a claim that's stale after
a deletion is exactly the lie this program exists to avoid.

The bundle's binary is the same one as the terminal —
`Cadastre.app/Contents/MacOS/cadastre ~/Code --clean` works.

```
swift build -c release

cadastre ~/Library --depth 2        # measure (Ctrl-C interrupts and shows the measured floor)
cadastre --disk                     # the whole Data volume, where everything deletable lives
cadastre --volumes                  # volume status only, no scan
cadastre ~ --lang en                # the language of messages; otherwise the system's, or CADASTRE_LANG

cadastre ~/Code --save auto         # keep a record
cadastre ~/Code --since last        # ... and see what's changed since
cadastre --diff a.cdst b.cdst       # compare two records, without scanning anything

cadastre ~ --clean                  # what's safe to delete, and the real gain
cadastre ~ --trash                  # ... to the Trash, after confirmation

cadastre ~ --ui                     # the map
cadastre ~ --ui --since last        # ... coloured by what changed
cadastre ~ --ui --find node_modules # ... with a search already typed in
cadastre ~ --ui --open reclaim      # ... opened on the "reclaim" panel
cadastre ~ --ui --since last --open changes   # ... or on "what changed"
cadastre --ui --disk                # this Mac: the map of the whole disk
cadastre ~ --snapshot carte.png     # PNG export, without opening a window
```

## The five metrics

The names on the left are the command-line ones; the app spells them out in
full.

| `--metric` | in the app | definition | what it's for |
|---|---|---|---|
| `logical` | Logical size | sum of forks, uncompressed | what Finder shows |
| `allocated` | Allocated blocks | blocks on disk, a clone counted in each file | reproduces `du` byte for byte |
| `attributed` | Real footprint | fair share of shared blocks | **the only additive metric**: its sum over a volume equals the real footprint |
| `exclusive` | Exclusive to entry | blocks shared with nothing | what deleting this entry *alone* frees up |
| `retained` | Reclaimable | `exclusive` + families entirely contained | what deleting the whole subtree frees up |

`attributed` is the default metric. `retained` is the one you look at before
deleting.

The gap between `allocated` and `attributed` is the amount that `du`,
GrandPerspective and Disk Inventory X double-count.

### Why `retained` ≠ sum of `exclusive`

Two clones of the same file in two different folders: each has
`exclusive = 0`, deleting one frees nothing. Deleting both frees everything.
A family of shared blocks is only reclaimable by the smallest folder that
contains it entirely — its *lowest common ancestor*. Cadastre credits that
folder, then walks back up the tree, which gives the right answer for every
ancestor in a single pass.

```
$ cadastre split/projetA        reclaimable:      0 B
$ cadastre split                reclaimable: 33.6 MB
```

## macOS pitfalls, and what's done about each one

| Pitfall | Handling |
|---|---|
| **Evicted iCloud files** | `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` before the first `open`. Without it, reading an evicted file's attributes triggers its download — a scan can re-download hundreds of GB. They're counted and reported separately. |
| **APFS clones** | `ATTR_CMNEXT_PRIVATESIZE` and `ATTR_CMNEXT_CLONE_REFCNT` give the exclusive blocks and the family's size. |
| **Hard links** | Fair share per entry, and LCA across the set of links for `retained`. |
| **Sparse files** | `ALLOCSIZE` instead of `st_size`: a Docker image reported at 64 GB with 8 GB real is seen as 8 GB. |
| **decmpfs compression** | The reverse case; the saving is measured and shown. |
| **Firmlinks** | `ATTR_CMNEXT_REALDEVID` sees through them: `/Users` seen from the system volume is recognised as belonging to the Data volume, and isn't counted twice. |
| **Mount points** | `ATTR_DIR_MOUNTSTATUS`, plus `IOPOL_VFS_TRIGGER_RESOLVE_OFF` to avoid mounting network shares along the way. |
| **Local snapshots** | Listed upfront: as long as they exist, deleting files frees nothing. |
| **Purgeable space** | `volumeAvailableCapacityForImportantUsage` minus `statfs`: the gap is what macOS counts as free because it's ready to throw something away. |
| **Invisible volumes** | Preboot, Recovery, VM, Update share the container's space without being on any scannable path. Often more than 10 GB. Listed via `diskutil apfs list`. |
| **Full Disk Access** | Probed at startup. Without it, Mail, Messages, Safari and iOS backups read as empty; Cadastre says so instead of showing a clean folder. |
| **Denied folders** | Counted and listed. An incomplete total is reported as a floor. |

## The map

Squarified treemap, rendered in Metal: one entry per file, animated zoom, the
five metrics switchable on the fly — it's the same map that answers "what's
big" and "what do I get back".

The scan runs inside the app, not before it: it opens a folder, shows
progress, and keeps the current position when you switch metric or marker.

Five ways to colour:

| | |
|---|---|
| **By file type** | six families: code, documents, images, video, audio, data |
| **By depth** | ordinal ramp — the clean equivalent of "linking common paths" |
| **By shared blocks** | how much of this rectangle is shared with something else |
| **By what changed** | bytes actually written since the loaded marker |
| **By reclaimability** | what the catalogue identified, and under what heading |

*By shared blocks* is the view unique to Cadastre: the darkest squares are
cloned blocks, which you won't reclaim by deleting what you see.

### Six families, and how they were chosen

A treemap is an **"all-pairs"** shape: any two rectangles can touch, so
*every* pair of colours has to stay distinguishable, not just neighbours in a
legend.

The first version took the eight hues of a reference palette and found that
only four survived this constraint. That was the wrong conclusion drawn from
the right test: that palette is a default instance, not a requirement, and
the method explicitly allows for a project to bring its own ramps and submit
them to the same threshold.

These hues were therefore **searched for**, not chosen: generated in OKLCH,
then kept by a greedy search under the **joint** constraint of both modes —
a set that works on a light background regularly fails on a dark one, where
the lightness band is half as wide.

Measured, all pairs:

| | light | dark | threshold |
|---|---|---|---|
| CVD separation | 9.3 | 7.6 | 8 targeted, 6 floor |
| normal vision | 17.5 | 16.8 | 15 |

Six hues instead of four, lighter, and with **better** separation in dark
mode than the previous four (7.6 versus 6.9). Images, video and audio each
get their own, which is the bulk of the gain in variety.

The dark set stays within the 6–8 band, which is only permissible with a
**secondary encoding**: hence the permanent, labelled legend, the family
name in the inspector on hover, the gutter between fills, and the label on
every rectangle large enough. These aren't ornaments to trim later.
Likewise, two hues fall below 3:1, which requires a tabular view: that's the
current level's list, in the inspector.

Pushing everything up into the lighter half of the band was tried: it costs
two hues. Lightness variation is itself part of what separates the colours,
so spending it entirely on brightness returns less than it costs.

Folders are **frames**, not fills. That's what leaves a surface-coloured
gutter between every pair of neighbouring fills, and what makes nesting
legible without spending a colour on it.

Label ink is chosen by **measured contrast ratio** against the fill, not by
a lightness threshold: several families sit at mid-lightness, where a fixed
threshold is bound to get one of them wrong. Below 3:1, a one-pixel halo of
the opposite ink recovers legibility — removing the label isn't an option,
it's the palette's secondary encoding.

### Checking the geometry

A layout bug doesn't crash: it draws something plausible that lies about
proportions, exactly the flaw this program exists to avoid.
`--self-test-layout` checks, on the real tree and across the five metrics,
that children fit inside their frame, fill it to within 1%, don't overlap,
and that each one's area matches its share of the value. On a personal
folder: 40,000 rectangles, proportion error 0.0000, median width/height
ratio 1.12.

## What changed

The question you actually ask is almost never "what's big" — you already
know that. It's "what ate forty gigabytes this week". A static treemap is a
snapshot and doesn't answer that.

```
$ cadastre ~/projet --since last

CHANGE  ~/projet
  from 10 Sep 09:14 to 17 Sep 15:28  (7d 6h)

    attributed     47.2 MB  →     105 MB    +57.7 MB

  WHERE IT MOVED  (change local to the folder)
           +52.4 MB  ~/projet/build
           -21.0 MB  ~/projet/assets  nothing written — share of shared blocks redistributed
  new      +18.9 MB  ~/projet/node_modules
```

Trees are matched by name, level by level — no path is built for the
matching, the comparison is linear. Two trees of 262,000 nodes are compared
in 68 ms, process start-up included.

### "nothing written"

Cloning a file into another folder halves the share credited to the
original. A folder nobody touched can therefore *shrink*. The diff measures
the change in `allocated` in parallel — the bytes actually written — and
flags the lines where the content hasn't moved and only the accounting has
shifted. Without that, the report is accurate and misleading. The map in
**By what changed** mode colours the bytes written, not the displayed
metric, for the same reason.

### In the window

`⌘D` opens the same change as a table: before, after, delta, then "where it
moved" — the folders that themselves wrote or lost bytes — and the files that
appeared, grew, shrank, vanished. Double-click a row and the map zooms to its
parent folder and selects the entry. With the colour set to "by what
changed", the current level's list in the inspector shows bytes written
rather than size, sorted by change: the "what ate forty gigabytes" reading
without leaving the window.

### Following changes

`⌘⇧L` puts an FSEvents watcher on the folder. Every write triggers a
background measure — no overlay, just a "measuring again…" in the footer —
and the previous measure becomes the marker: the map colours exactly what
just moved. Start a build, watch `DerivedData` turn red.

The trigger is incremental; the measure is not. Clone families and
reclaimable bytes are settled over the whole scan, and a tree patched one
folder at a time would slowly drift from the disk. A two-second measure is
cheaper than that drift. Events are coalesced: a build writes thousands of
files over a few seconds, and one measure at the end is worth more than ten
in the middle; a slow folder is re-measured only after a few scan durations.

### Markers

`⌘S` in the app, `--save auto` on the command line: the folder's state is
written to the local history. Later, the "compare to" menu offers the
markers dropped on that same folder.

They're dated by the **scan**'s time, read from their file name, not by the
file's modification date: a marker saved ten minutes after the fact would
otherwise point to a moment that isn't the one it contains — and a session
would offer itself its own marker as a point of comparison.

`CADASTRE_HOME` moves the history somewhere other than
`~/Library/Application Support/Cadastre`.

### The index

A saved scan is a flat binary file: header, fixed-width records, a names
arena. JSON was tempting and it's the wrong shape — a few million nodes cost
more to read back than to rescan. Only the sizes *proper* to each node are
stored; subtree totals are recomputed on load, which keeps them from
drifting.

220,000 files and 42,000 folders fit in 22 MB, read back in 68 ms.

## The whole disk

`⌘⇧O` in the app, `--disk` on the command line. This is not a scan of `/`:
since Catalina, `/` is the sealed system volume, and `/Users`, `/Applications`
or `/Library` are firmlinks into the Data volume. Cadastre measures the Data
volume at its real mount point, `/System/Volumes/Data`, where everything a
person can delete lives, and adds the container's other volumes — the sealed
system, Preboot, Recovery, VM — as grey tiles, with their usage read from
`diskutil`. The map then adds up to the disk's used space, not a folder's.

Free space is a setting (View › Show Free Space on the Map), off by default:
on a half-empty disk it is three quarters of the map and crushes everything
else. The figure stays in the root's inspector, with the purgeable share.

The catalogue and the guards see through the prefix:
`/System/Volumes/Data/Users/x/Library/Caches` is recognised as
`~/Library/Caches`, and is not taken for part of `/System`. Without Full Disk
Access the app says so before measuring, with the button that opens the right
setting — 207 refused folders on an ordinary Mac, and a total announced as a
floor.

## Safe to delete

The principle behind this catalogue is that **a name is never enough**.
`build` is a compiler's output in one project and ten years of work in
another. Every rule therefore requires proof — a `package.json` next to
`node_modules`, a `Cargo.toml` next to `target`, a `CMakeCache.txt` inside
`build` — and a folder that can't produce it isn't offered. Being useless
can be forgiven, being wrong can't.

Three levels, and the third is never deleted by the program:

| | |
|---|---|
| `REGENERABLE` | rebuilt by a tool from files that are still there |
| `CACHE` | refills itself — you lose time, not data |
| `YOUR CALL` | large and often useless, but irreplaceable: iOS backups, Xcode archives, Trash |

Guards applied to every candidate, at report time **and** again right
before deletion, because a scan is a snapshot and the disk keeps moving:

- never a symbolic link
- never a folder containing a `.git` — a working tree isn't a build output
- never under `/System`, `/usr`, `/bin`, `/Applications`, `/private/var/db`…
- never a candidate nested inside another (otherwise everything is counted twice)
- deletion goes to the **Trash**, never `unlink`: these rules are
  heuristics, and a heuristic needs an undo

### The gain isn't the sum of its parts

pnpm hard-links every project's dependencies to a shared store. Deleting a
single `node_modules` frees almost nothing; deleting all of them frees a
lot. Cadastre computes the gain of the selected **set**, not the sum of the
individual gains:

```
     4.19 MB  projA/node_modules   · 15.7 MB shared outside this folder
         0 B  projB/node_modules   · 15.7 MB shared outside this folder

  TOTAL RECLAIMABLE  56.6 MB
  that is 31.5 MB more than deleting them one by one
```

`⌘R` opens the same catalogue as a checkable list, and the total at the
bottom recomputes with every checkbox: that's why checking a second box can
free more than that box is worth on its own.

And if a local snapshot exists, the report says so: the space won't come
back until it expires, no matter what you delete.

## Speed

`getattrlistbulk(2)` returns the name *and* all the size attributes for a
few hundred entries per call. The `readdir` + `lstat` per file used by
classic tools costs one syscall per file.

~262,000 entries in 2.1 s on internal SSD (≈120,000 entries/s, 8 threads),
2.3 s with a per-file record kept and the index written.

## Two languages, one binary

There's no resource bundle to look up: the program is a single binary,
which is both the app and the command-line tool, and a launch from the
terminal has no `.lproj` at hand. Every visible string is therefore written
in place, in both languages, via `tr(en:fr:)` — English first, French
second, everywhere. It's more verbose than a key table, and much harder to
leave a string untranslated.

The language is chosen in this order: `--lang`, then `CADASTRE_LANG`, then
the preference set from the app's menu, then the system language. Units
follow suit: "6,3 Go" in French, "6.3 GB" in English, like Finder. The
permission-request descriptions (Desktop, Documents…) are the only strings
outside the binary: macOS reads them from `InfoPlist.strings`, which
`bundle.sh` writes in both languages.

Switching language from the menu rebuilds the window rather than relabelling
its controls: every menu, panel and header was built by `tr()` when it was
created, and a fresh controller is the one place that catches all of them. The
deletion catalogue is re-evaluated on each access for the same reason — its
labels live in the session, and the folder is measured again.

## Interface notes

The two toolbar menus aren't named after the code: the displayed metric is
spelled out in full at the bottom of the window ("Area · Real footprint —
fair share of shared blocks…"), and the legend is prefixed with what it's a
legend for ("Colour · By file type ·"). A menu that shows `attributed` next
to `exclusive` explains nothing to anyone who hasn't read the source.

The window is an `NSSplitViewController`: unified toolbar in the title bar,
glassy inspector on the right, map in the centre. The first version stacked
a title bar, a controls strip and a breadcrumb — three bands of chrome above
the thing you came to look at.

In the inspector, values sit on a right-hand tab stop and are grouped under
quiet headers. Before, each figure followed its label: accurate, and
unreadable at a glance. The field recomputes its line width on every layout
pass: an ordinary `NSTextField` reports the width of its whole string as its
intrinsic size, and a long file name would widen the panel on every hover.

The hover test returns the found index directly, instead of re-scanning the
forty thousand rectangles to find what the search already had in hand. It
was redundant work; I didn't measure a perceptible difference.

Keyboard selection is a ring in the accent colour, distinct from hover: the
pointer and the arrow keys can point at two different things. The arrow
keys pick the neighbour *by on-screen position* among siblings, not by rank
in a list — whatever is to the right of the selection is what the eye
expects `→` to reach.

Search doesn't filter, it dims: rectangles that don't match fade into the
surface, the ones that match keep their colour, and a folder whose name
matches lights up everything it contains. The window's footer gives the
count and the total of top-level matches — a matching folder and the files
it contains make a single total, not two.

The root frame has no title band: its name is already in the breadcrumb,
and its frame is the window. The first version showed it twice.

An interrupted scan is shown as is, marked "partial" in orange in the
window's footer, and a folder denied for lack of permission is marked the
same way. An incomplete total reported as complete is exactly the lie this
program exists to avoid; a floor reported as a floor isn't one.

## Structure

```
Package.swift            C target + executable, macOS 14
Sources/CadastreC/
  include/CadastreC.h    interface: I/O policies, bulk decoding
  bulk.c                 getattrlistbulk, packed buffer decoding
Sources/cadastre/
  L10n.swift             the two languages: tr(en:fr:), units, dates, preference
  Tree.swift             struct-of-arrays tree, LCA, roll-up, file table
  Families.swift         clones and hard links: who owns which blocks
  Walker.swift           parallel, interruptible traversal
  Index.swift            binary format, local history
  Diff.swift             matching two scans
  Reclaim.swift          proof-based catalogue, guards, moving to Trash
  VolumeReport.swift     container, snapshots, purgeable, TCC
  Format.swift           terminal rendering
  main.swift             CLI, JSON exports
Sources/cadastre/UI/
  Treemap.swift          flattened model, merging of single-child chains
  TreemapLayout.swift    squarified (Bruls, Huizing, van Wijk 2000)
  LayoutSelfTest.swift   geometry invariants
  Palette.swift          searched-for palette, and the reasoning that fixed its size
  TreemapRenderer.swift  rectangles instanced in Metal
  TreemapView.swift      hover, selection, keyboard, search, animated zoom, context menu
  LabelPass.swift        labels, ink chosen by measured contrast
  Legend.swift           permanent, labelled legend
  Window.swift           window, toolbar, menus, breadcrumb, inspector, empty state
  Session.swift          analysed folder, markers, background scan, whole disk, recents
  FileWatcher.swift      FSEvents: the trigger behind "follow changes"
  DiffSheet.swift        "what changed" as a table, leading back to the map
  ReclaimSheet.swift     checkable catalogue, combined gain, re-verification
  Snapshot.swift         off-screen PNG export
  Icon.swift             icon, tiled by the same algorithm as the map
Tests/cadastreTests/
  AccountingTests.swift  families, layout, units, guards, diff — on synthetic trees
Scripts/
  verify.sh              ground truth: every case has an answer known by construction
  bundle.sh              builds Cadastre.app (ad hoc signature)
  release.sh             the same, signed and notarised when CODESIGN_IDENTITY
                         and NOTARY_PROFILE are set, zipped into dist/ with the CLI
```

`swift test` covers the corners a real disk does not produce on demand: a
family straddling two folders, a hard link whose two names must go together,
a root frame with no title band, units in both languages.

`Scripts/verify.sh` builds real files on a real APFS volume — these numbers
come from the filesystem, they can't be tested dry — and checks, among other
things, that `allocated` reproduces `du` exactly, that the treemap's
geometry is accurate to within 1%, and that the bundle builds.

## Left to do

- A truly incremental measure behind FSEvents: re-read only the folders
  that changed, and settle again only the families they hold
- The size of local snapshots, which `tmutil` does not give; they stay a
  warning line rather than a tile
- An animated transition between two measures: switching the area metric
  reorganises every rectangle at once, and the eye loses what it was following
- The signature is ad hoc without a Developer ID identity: `Scripts/release.sh`
  knows how to sign and notarise, it only lacks the credentials
