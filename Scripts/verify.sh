#!/bin/bash
# Ground-truth checks for the accounting model.
#
# These cannot be unit tests: the numbers under test come from the filesystem
# itself, so the fixture has to be real files on a real APFS volume. Each case
# is one where the correct answer is known by construction.
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release >/dev/null
CADASTRE="$PWD/.build/release/cadastre"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Keep the suite out of the real marker history.
export CADASTRE_HOME="$WORK/store"

MIB=$((1024 * 1024))
FAILED=0

measure() {  # measure <dir> <metric-key>
  "$CADASTRE" "$1" --json "$WORK/out.json" --depth 0 --top 0 --no-color >/dev/null 2>&1
  python3 -c "import json,sys; print(json.load(open('$WORK/out.json'))['root']['$2'])"
}

check() {  # check <label> <actual> <expected> <tolerance>
  local label="$1" actual="$2" expected="$3" tolerance="$4"
  local delta=$(( actual > expected ? actual - expected : expected - actual ))
  if [ "$delta" -le "$tolerance" ]; then
    printf '  \033[32mok\033[0m   %-52s %s\n' "$label" "$actual"
  else
    printf '  \033[31mFAIL\033[0m %-52s %s (attendu %s)\n' "$label" "$actual" "$expected"
    FAILED=1
  fi
}

TOL=$((256 * 1024))   # directory metadata blocks

echo "fichier simple de 16 MiB"
mkdir -p "$WORK/plain"
dd if=/dev/urandom of="$WORK/plain/a.bin" bs=1m count=16 2>/dev/null
check "alloué"      "$(measure "$WORK/plain" allocated)"  $((16 * MIB)) $TOL
check "réel"        "$(measure "$WORK/plain" attributed)" $((16 * MIB)) $TOL
check "récupérable" "$(measure "$WORK/plain" retained)"   $((16 * MIB)) $TOL

echo "clone APFS: deux noms, un seul jeu de blocs"
mkdir -p "$WORK/clone"
dd if=/dev/urandom of="$WORK/clone/a.bin" bs=1m count=16 2>/dev/null
cp -c "$WORK/clone/a.bin" "$WORK/clone/b.bin"
check "alloué compte les deux (comme du)" "$(measure "$WORK/clone" allocated)"  $((32 * MIB)) $TOL
check "réel n'en compte qu'un"            "$(measure "$WORK/clone" attributed)" $((16 * MIB)) $TOL
check "récupérable"                       "$(measure "$WORK/clone" retained)"   $((16 * MIB)) $TOL

echo "lien dur: deux entrées, un seul inode"
mkdir -p "$WORK/link"
dd if=/dev/urandom of="$WORK/link/a.bin" bs=1m count=16 2>/dev/null
ln "$WORK/link/a.bin" "$WORK/link/b.bin"
check "réel"        "$(measure "$WORK/link" attributed)" $((16 * MIB)) $TOL
check "récupérable" "$(measure "$WORK/link" retained)"   $((16 * MIB)) $TOL

echo "famille de clones à cheval sur deux dossiers"
mkdir -p "$WORK/split/a" "$WORK/split/b"
dd if=/dev/urandom of="$WORK/split/a/m.bin" bs=1m count=16 2>/dev/null
cp -c "$WORK/split/a/m.bin" "$WORK/split/b/m.bin"
check "un seul côté ne libère rien"   "$(measure "$WORK/split/a" retained)" 0            $TOL
check "les deux côtés libèrent tout"  "$(measure "$WORK/split" retained)"   $((16 * MIB)) $TOL

echo "fichier creux de 100 Mo"
mkdir -p "$WORK/sparse"
dd if=/dev/zero of="$WORK/sparse/s.bin" bs=1 count=1 seek=100000000 2>/dev/null
check "logique annonce la taille nominale" "$(measure "$WORK/sparse" logical)" 100000001 $TOL
check "réel ne compte que les blocs"       "$(measure "$WORK/sparse" attributed)" 0      $TOL

echo "accord avec du sur un arbre réel"
DU=$(($(du -sk "$PWD/Sources" | cut -f1) * 1024))
check "alloué == du" "$(measure "$PWD/Sources" allocated)" "$DU" $TOL

# --- index et diff -----------------------------------------------------------

field() {  # field <json> <clé>
  python3 -c "import json;print(json.load(open('$1'))['$2'])"
}

echo "l'index relu reproduit le scan"
mkdir -p "$WORK/idx/a" "$WORK/idx/b"
dd if=/dev/urandom of="$WORK/idx/a/un.bin" bs=1m count=8 2>/dev/null
dd if=/dev/urandom of="$WORK/idx/b/deux.bin" bs=1m count=4 2>/dev/null
LIVE=$(measure "$WORK/idx" attributed)
"$CADASTRE" "$WORK/idx" --save "$WORK/t0.cdst" --depth 0 --top 0 --no-color >/dev/null 2>&1
"$CADASTRE" --diff "$WORK/t0.cdst" "$WORK/t0.cdst" --json "$WORK/same.json" >/dev/null 2>&1
check "total identique après aller-retour" "$(field "$WORK/same.json" totalAfter)" "$LIVE" 0
check "écart nul contre lui-même"          "$(field "$WORK/same.json" delta)"      0      0

echo "le diff voit ce qui est arrivé"
dd if=/dev/urandom of="$WORK/idx/b/trois.bin" bs=1m count=16 2>/dev/null
rm "$WORK/idx/a/un.bin"
"$CADASTRE" "$WORK/idx" --since "$WORK/t0.cdst" --json "$WORK/moved.json" >/dev/null 2>&1
check "écart total"        "$(field "$WORK/moved.json" delta)"        $((8 * MIB))  $TOL
check "un fichier apparu"  "$(field "$WORK/moved.json" addedFiles)"   1             0
check "un fichier disparu" "$(field "$WORK/moved.json" removedFiles)" 1             0

echo "un clone n'est pas une écriture"
mkdir -p "$WORK/share/gauche" "$WORK/share/droite"
dd if=/dev/urandom of="$WORK/share/gauche/m.bin" bs=1m count=32 2>/dev/null
"$CADASTRE" "$WORK/share" --save "$WORK/s0.cdst" --depth 0 --top 0 --no-color >/dev/null 2>&1
cp -c "$WORK/share/gauche/m.bin" "$WORK/share/droite/m.bin"
"$CADASTRE" "$WORK/share" --since "$WORK/s0.cdst" --json "$WORK/share.json" >/dev/null 2>&1
check "cloner ne consomme rien" "$(field "$WORK/share.json" delta)" 0 $TOL
SHARING=$(python3 -c "
import json
d = json.load(open('$WORK/share.json'))
left = [x for x in d['directories'] if x['path'].endswith('gauche')]
print(1 if left and left[0].get('sharingOnly') else 0)")
check "la baisse de gauche/ est signalée comme un partage" "$SHARING" 1 0

# --- catalogue « sûr à supprimer » -------------------------------------------

clean_json() {  # clean_json <dir>
  "$CADASTRE" "$1" --clean --json "$WORK/clean.json" >/dev/null 2>&1
  cat "$WORK/clean.json"
}

echo "le catalogue exige une preuve"
mkdir -p "$WORK/proof"/{bon,sans-manifeste,build-quelconque,depot}
# preuve présente : un package.json à côté
mkdir -p "$WORK/proof/bon/node_modules"
echo '{}' > "$WORK/proof/bon/package.json"
dd if=/dev/urandom of="$WORK/proof/bon/node_modules/x.bin" bs=1m count=8 2>/dev/null
# pas de package.json
mkdir -p "$WORK/proof/sans-manifeste/node_modules"
dd if=/dev/urandom of="$WORK/proof/sans-manifeste/node_modules/x.bin" bs=1m count=8 2>/dev/null
# un dossier « build » sans CMakeCache.txt n'est pas une sortie de compilation
mkdir -p "$WORK/proof/build-quelconque/build"
dd if=/dev/urandom of="$WORK/proof/build-quelconque/build/x.bin" bs=1m count=8 2>/dev/null
# un node_modules qui contient un dépôt git est un arbre de travail
mkdir -p "$WORK/proof/depot/node_modules/.git"
echo '{}' > "$WORK/proof/depot/package.json"
dd if=/dev/urandom of="$WORK/proof/depot/node_modules/x.bin" bs=1m count=8 2>/dev/null

RETENUS=$(clean_json "$WORK/proof" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(' '.join(sorted(c['path'].split('/proof/')[1] for c in d['candidates'])))")
check "seul le dossier avec preuve est retenu" "$([ "$RETENUS" = "bon/node_modules" ] && echo 1 || echo 0)" 1 0
printf '       retenus: %s\n' "${RETENUS:-aucun}"

echo "le gain d'un ensemble n'est pas la somme des parties"
mkdir -p "$WORK/pnpm"/{a/node_modules,b/node_modules}
echo '{}' > "$WORK/pnpm/a/package.json"; echo '{}' > "$WORK/pnpm/b/package.json"
dd if=/dev/urandom of="$WORK/pnpm/a/node_modules/partage.bin" bs=1m count=24 2>/dev/null
ln "$WORK/pnpm/a/node_modules/partage.bin" "$WORK/pnpm/b/node_modules/partage.bin"
clean_json "$WORK/pnpm" > "$WORK/pnpm.json"
# Chaque node_modules seul ne libère rien — le lien dur est dans l'autre.
check "un par un : rien"       "$(field "$WORK/pnpm.json" individualSum)" 0             0
check "ensemble : tout"        "$(field "$WORK/pnpm.json" combinedFreed)" $((24 * MIB)) $TOL

echo "les gardes de sûreté"
mkdir -p "$WORK/guards/lien" "$WORK/guards/ailleurs"
echo '{}' > "$WORK/guards/lien/package.json"
dd if=/dev/urandom of="$WORK/guards/ailleurs/precieux.bin" bs=1m count=8 2>/dev/null
ln -s "$WORK/guards/ailleurs" "$WORK/guards/lien/node_modules"
# node_modules imbriqué : seul l'extérieur doit être proposé, sinon on compte deux fois
mkdir -p "$WORK/guards/imbrique/node_modules/paquet/node_modules"
echo '{}' > "$WORK/guards/imbrique/package.json"
echo '{}' > "$WORK/guards/imbrique/node_modules/paquet/package.json"
dd if=/dev/urandom of="$WORK/guards/imbrique/node_modules/paquet/node_modules/x.bin" bs=1m count=8 2>/dev/null

GUARDS=$(clean_json "$WORK/guards" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(' '.join(sorted(c['path'].split('/guards/')[1] for c in d['candidates'])))")
check "un lien symbolique n'est jamais proposé" "$([ "${GUARDS#*lien}" = "$GUARDS" ] && echo 1 || echo 0)" 1 0
check "seul le node_modules extérieur est proposé" "$([ "$GUARDS" = "imbrique/node_modules" ] && echo 1 || echo 0)" 1 0
printf '       retenus: %s\n' "${GUARDS:-aucun}"

echo "les entrées « à votre appréciation » restent hors du total"
clean_json "$HOME" > "$WORK/home.json"
read -r VERDICT DETAIL <<<"$(python3 -c "
import json
d = json.load(open('$WORK/home.json'))
review    = [c for c in d['candidates'] if c['confidence'] == 'review']
supprimable = sum(c['retained'] for c in d['candidates'] if c['confidence'] != 'review')
if not review:
    print('skip aucune-entree-review-sur-cette-machine')
else:
    exclu = sum(c['retained'] for c in review)
    ok = d['individualSum'] == supprimable and exclu > 0
    print(('1' if ok else '0'), f'{len(review)}-entrees-{exclu}-octets-exclus')
")"
if [ "$VERDICT" = "skip" ]; then
  printf '  \033[33mskip\033[0m %-52s %s\n' "pas d'entrée « review » ici" "$DETAIL"
else
  check "le total supprimable les exclut" "$VERDICT" 1 0
  printf '       %s\n' "$DETAIL"
fi

# --- carte -------------------------------------------------------------------

echo "la géométrie du treemap"
"$CADASTRE" "$WORK/proof" --self-test-layout --no-color > "$WORK/layout.txt" 2>&1 || true
check "les cinq métriques passent" "$(grep -c '^  ok ' "$WORK/layout.txt")" 5 0
# `|| true`: grep exits 1 when it finds nothing, which under `set -e` would
# abort the suite exactly when everything is fine.
grep '^  FAIL' "$WORK/layout.txt" | head -3 | sed 's/^/       /' || true
# Proportion error is the one that matters: a rectangle whose area does not
# match its share is a picture that lies.
WORST=$(sed -n 's/.*erreur max \([0-9.]*\).*/\1/p' "$WORK/layout.txt" | sort -rn | head -1)
check "erreur de proportion nulle" "$(python3 -c "print(1 if float('${WORST:-1}') < 0.01 else 0)")" 1 0

echo "la carte se rend hors écran"
"$CADASTRE" "$WORK/proof" --snapshot "$WORK/map.png" --size 800x500 >/dev/null 2>&1
check "largeur du PNG"     "$(sips -g pixelWidth  "$WORK/map.png" | awk '/pixelWidth/{print $2}')"  1600 0
check "hauteur du PNG"     "$(sips -g pixelHeight "$WORK/map.png" | awk '/pixelHeight/{print $2}')" 1000 0
# Une image unie se compresse en quelques kilo-octets ; au-delà, quelque chose
# a réellement été dessiné.
check "l'image n'est pas unie" "$([ "$(stat -f%z "$WORK/map.png")" -gt 8000 ] && echo 1 || echo 0)" 1 0

# --- repères et application --------------------------------------------------

echo "les repères vont et viennent"
mkdir -p "$WORK/repere"
dd if=/dev/urandom of="$WORK/repere/a.bin" bs=1m count=6 2>/dev/null
"$CADASTRE" "$WORK/repere" --save auto --depth 0 --top 0 --no-color >/dev/null 2>&1
check "un repère est listé" "$("$CADASTRE" --history | grep -c '\.cdst')" 1 0
# Rien n'a bougé : se comparer à son propre repère doit donner zéro.
"$CADASTRE" "$WORK/repere" --since last --json "$WORK/same-again.json" >/dev/null 2>&1
check "« last » retrouve le repère et l'écart est nul" \
      "$(field "$WORK/same-again.json" delta)" 0 0

echo "les deux langues"
check "l'aide en anglais"   "$("$CADASTRE" --lang en --help | grep -c '^Options')" 1 0
check "l'aide en français"  "$("$CADASTRE" --lang fr --help | grep -c '^Options')" 1 0
FR_UNITS=$("$CADASTRE" --lang fr "$WORK/plain" --depth 0 --top 0 --no-color | grep -c 'Mo' || true)
EN_UNITS=$("$CADASTRE" --lang en "$WORK/plain" --depth 0 --top 0 --no-color | grep -c 'MB' || true)
check "« Mo » en français"  "$([ "$FR_UNITS" -gt 0 ] && echo 1 || echo 0)" 1 0
check "« MB » en anglais"   "$([ "$EN_UNITS" -gt 0 ] && echo 1 || echo 0)" 1 0
check "une option inconnue échoue proprement" "$("$CADASTRE" --lang en --bogus >/dev/null 2>&1; echo $?)" 2 0

echo "un chemin relatif devient absolu"
( cd "$WORK" && "$CADASTRE" plain --json "$WORK/rel.json" --depth 0 --top 0 --no-color >/dev/null 2>&1 )
check "le nom de la racine est absolu" "$(python3 -c "import json;print(1 if json.load(open('$WORK/rel.json'))['root']['name'].startswith('/') else 0)")" 1 0

echo "l'application s'empaquette"
./Scripts/bundle.sh "$WORK/Cadastre.app" >/dev/null 2>&1
check "exécutable en place" "$([ -x "$WORK/Cadastre.app/Contents/MacOS/cadastre" ] && echo 1 || echo 0)" 1 0
check "icône en place"      "$([ -s "$WORK/Cadastre.app/Contents/Resources/Cadastre.icns" ] && echo 1 || echo 0)" 1 0
check "Info.plist valide"   "$(plutil -lint "$WORK/Cadastre.app/Contents/Info.plist" >/dev/null 2>&1 && echo 1 || echo 0)" 1 0
# Le même binaire doit rester utilisable en ligne de commande depuis le bundle.
check "le binaire du bundle reste un CLI" \
      "$("$WORK/Cadastre.app/Contents/MacOS/cadastre" --help >/dev/null 2>&1 && echo 1 || echo 0)" 1 0

exit $FAILED
