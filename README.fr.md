# Cadastre

*[English version](README.md)*

Mesure d'occupation disque sur macOS, conçue autour d'une idée : sur APFS,
« quelle taille ça fait » et « qu'est-ce que je récupère si je le supprime »
sont deux questions différentes, avec deux réponses différentes.

Une application avec une carte, et le même binaire en ligne de commande. Les
deux parlent français et anglais, selon la langue du système.

## Prendre en main

```
./Scripts/bundle.sh        # produit Cadastre.app
open Cadastre.app
```

Double-clic : elle propose un dossier — ou l'un des derniers mesurés —, le
mesure, affiche la carte. Un dossier déposé sur la fenêtre ou sur l'icône du
Dock est mesuré aussi.

| | |
|---|---|
| `⌘O` | choisir un dossier · le menu Fichier garde les huit derniers |
| `⌘⇧R` | mesurer à nouveau le même dossier |
| `⌘S` | poser un repère, pour comparer plus tard |
| `⌘R` | le panneau « récupérer de l'espace » |
| `⌘E` | exporter la carte en PNG |
| `⌘F` | chercher un nom : tout ce qui ne correspond pas s'efface |
| `⌘1`…`⌘5` | la mesure · `⌥⌘1`…`⌥⌘5` la couleur |
| double clic · `↩` | descendre dans un dossier · `⌫` ou `⌘↑` pour remonter, `⌘⇧↑` jusqu'à la racine |
| `←` `→` `↑` `↓` | passer d'un rectangle à son voisin · `⇥` pour entrer dans la sélection |
| clic droit | ouvrir, révéler dans le Finder, copier le chemin, mettre à la corbeille |
| `⌥⌘I` | masquer l'inspecteur |
| `⌘.` | arrêter un scan en cours — la carte est affichée telle quelle, marquée partielle |

Le menu Cadastre › Langue force le français ou l'anglais, indépendamment du
système ; ça s'applique au prochain lancement.

Le menu « comparer à » de la barre d'outils liste les repères déjà posés sur ce
dossier. Après une suppression, la carte est **re-mesurée**, jamais rapiécée :
chaque chiffre affiché est une affirmation sur le disque, et une affirmation
périmée après une suppression est exactement le mensonge que ce programme
existe pour éviter.

Le binaire du bundle est celui du terminal —
`Cadastre.app/Contents/MacOS/cadastre ~/Code --clean` fonctionne.

```
swift build -c release

cadastre ~/Library --depth 2        # mesurer (Ctrl-C interrompt et affiche le plancher mesuré)
cadastre --volumes                  # état des volumes seul, sans scan
cadastre ~ --lang en                # la langue des messages ; sinon celle du système, ou CADASTRE_LANG

cadastre ~/Code --save auto         # garder une trace
cadastre ~/Code --since last        # ... et voir ce qui a bougé depuis
cadastre --diff a.cdst b.cdst       # comparer deux traces, sans rien scanner

cadastre ~ --clean                  # ce qui est sûr à supprimer, et le gain réel
cadastre ~ --trash                  # ... vers la corbeille, après confirmation

cadastre ~ --ui                     # la carte
cadastre ~ --ui --since last        # ... colorée par ce qui a changé
cadastre ~ --ui --find node_modules # ... avec une recherche déjà saisie
cadastre ~ --ui --clean             # ... ouverte sur le panneau « récupérer »
cadastre ~ --snapshot carte.png     # export PNG, sans ouvrir de fenêtre
```

## Les cinq mesures

Les noms de gauche sont ceux de la ligne de commande ; l'application les écrit
en toutes lettres.

| `--metric` | dans l'app | définition | à quoi ça sert |
|---|---|---|---|
| `logical` | Taille logique | somme des forks, non compressée | ce que montre le Finder |
| `allocated` | Blocs alloués | blocs sur disque, un clone compté dans chaque fichier | reproduit `du` à l'octet près |
| `attributed` | Occupation réelle | part équitable des blocs partagés | **seule mesure additive** : sa somme sur un volume égale l'occupation réelle |
| `exclusive` | Exclusif à l'entrée | blocs partagés avec rien | ce que libère la suppression de cette entrée *seule* |
| `retained` | Récupérable | `exclusive` + les familles entièrement contenues | ce que libère la suppression de tout le sous-arbre |

`attributed` est la mesure par défaut. `retained` est celle qu'on regarde avant
de supprimer.

L'écart entre `allocated` et `attributed` est la quantité que `du`,
GrandPerspective et Disk Inventory X comptent en double.

### Pourquoi `retained` ≠ somme des `exclusive`

Deux clones du même fichier dans deux dossiers différents : chacun a
`exclusive = 0`, supprimer l'un ne libère rien. Supprimer les deux libère tout.
Une famille de blocs partagés n'est récupérable que par le plus petit dossier
qui la contient entièrement — son *plus proche ancêtre commun*. Cadastre
crédite ce dossier, puis remonte l'arbre, ce qui donne la bonne réponse pour
tous les ancêtres en une passe.

```
$ cadastre split/projetA        récupérable :      0 B
$ cadastre split                récupérable : 33.6 MB
```

## Les pièges macOS, et ce qui est fait pour chacun

| Piège | Traitement |
|---|---|
| **Fichiers iCloud évincés** | `IOPOL_MATERIALIZE_DATALESS_FILES_OFF` avant le premier `open`. Sans ça, lire les attributs d'un fichier évincé déclenche son rapatriement — un scan peut retélécharger des centaines de Go. Ils sont comptés et signalés à part. |
| **Clones APFS** | `ATTR_CMNEXT_PRIVATESIZE` et `ATTR_CMNEXT_CLONE_REFCNT` donnent les blocs exclusifs et la taille de la famille. |
| **Liens durs** | Part équitable par entrée, et LCA sur l'ensemble des liens pour `retained`. |
| **Fichiers creux** | `ALLOCSIZE` au lieu de `st_size` : une image Docker de 64 Go annoncés pour 8 Go réels est vue à 8 Go. |
| **Compression decmpfs** | Le cas inverse ; l'économie est mesurée et affichée. |
| **Firmlinks** | `ATTR_CMNEXT_REALDEVID` voit à travers : `/Users` vu depuis le volume système est reconnu comme appartenant au volume Data, et n'est pas compté deux fois. |
| **Points de montage** | `ATTR_DIR_MOUNTSTATUS`, plus `IOPOL_VFS_TRIGGER_RESOLVE_OFF` pour ne pas monter de partages réseau en passant. |
| **Snapshots locaux** | Listés d'emblée : tant qu'ils existent, supprimer des fichiers ne libère rien. |
| **Espace purgeable** | `volumeAvailableCapacityForImportantUsage` moins `statfs` : l'écart est ce que macOS compte comme libre parce qu'il est prêt à jeter quelque chose. |
| **Volumes invisibles** | Preboot, Recovery, VM, Update partagent l'espace du conteneur sans être sur aucun chemin scannable. Souvent plus de 10 Go. Listés via `diskutil apfs list`. |
| **Accès disque complet** | Sondé au démarrage. Sans lui, Mail, Messages, Safari et les sauvegardes iOS se lisent comme vides ; Cadastre le dit au lieu d'afficher un dossier propre. |
| **Dossiers refusés** | Comptés et listés. Un total incomplet est annoncé comme un plancher. |

## La carte

Treemap squarifié, rendu en Metal : une entrée par fichier, zoom animé, les
cinq mesures commutables à chaud — c'est la même carte qui répond à « qu'est-ce
qui est gros » et à « qu'est-ce que je récupère ».

Le scan tourne dans l'application, pas avant elle : elle ouvre un dossier,
affiche la progression, et garde la position courante quand on change de mesure
ou de repère.

Cinq façons de colorer :

| | |
|---|---|
| **Par type de fichier** | six familles : code, documents, images, vidéo, audio, données |
| **Par profondeur** | rampe ordinale — l'équivalent propre du « lier les chemins communs » |
| **Par blocs partagés** | quelle part de ce rectangle est partagée avec autre chose |
| **Par ce qui a changé** | octets réellement écrits depuis le repère chargé |
| **Par récupérabilité** | ce que le catalogue a identifié, et à quel titre |

*Par blocs partagés* est la vue propre à Cadastre : les carrés les plus foncés
sont des blocs clonés, que vous ne récupérerez pas en supprimant ce que vous
voyez.

### Six familles, et comment elles ont été choisies

Un treemap est une forme **« toutes paires »** : n'importe quels deux
rectangles peuvent se toucher, donc *chaque* paire de couleurs doit rester
séparable, pas seulement les voisines d'une légende.

La première version a pris les huit teintes d'une palette de référence et
constaté que quatre seulement survivaient à cette contrainte. C'était la
mauvaise conclusion tirée du bon test : cette palette est une instance par
défaut, pas une obligation, et la méthode prévoit explicitement qu'un projet
apporte ses propres rampes et les soumette au même seuil.

Ces teintes ont donc été **cherchées**, pas choisies : générées en OKLCH, puis
retenues par une recherche gloutonne sous contrainte **conjointe** des deux
modes — un jeu qui marche sur fond clair échoue régulièrement sur fond sombre,
où la bande de clarté est deux fois plus étroite.

Mesuré, toutes paires :

| | clair | sombre | seuil |
|---|---|---|---|
| séparation CVD | 9,3 | 7,6 | 8 visé, 6 plancher |
| vision normale | 17,5 | 16,8 | 15 |

Six teintes au lieu de quatre, plus claires, et avec une **meilleure**
séparation en mode sombre que les quatre précédentes (7,6 contre 6,9). Images,
vidéo et audio ont chacune la leur, ce qui est l'essentiel du gain de variété.

Le jeu sombre reste dans la bande 6–8, ce qui n'est permis qu'avec un
**encodage secondaire** : d'où la légende permanente et légendée, le nom de la
famille dans l'inspecteur au survol, la gouttière entre remplissages, et
l'étiquette sur chaque rectangle assez grand. Ce ne sont pas des ornements à
rogner plus tard. De même, deux teintes passent sous 3:1, ce qui oblige à une
vue tabulaire : c'est la liste du niveau courant, dans l'inspecteur.

Tout remonter dans la moitié claire de la bande a été essayé : ça coûte deux
teintes. La variation de clarté fait elle-même partie de ce qui sépare les
couleurs, donc la dépenser entièrement en luminosité rapporte moins qu'elle ne
coûte.

Les dossiers sont des **cadres**, pas des aplats. C'est ce qui laisse une
gouttière couleur surface entre chaque paire de remplissages voisins, et ce qui
rend l'imbrication lisible sans y dépenser une couleur.

L'encre des étiquettes est choisie par **rapport de contraste mesuré** contre le
remplissage, pas par un seuil de luminosité : plusieurs familles sont à
mi-clarté, là où un seuil fixe se trompe forcément sur l'une d'elles. Sous 3:1,
un halo d'un pixel de l'encre opposée rattrape la lisibilité — supprimer
l'étiquette n'est pas une option, c'est l'encodage secondaire de la palette.

### Vérifier la géométrie

Une erreur de mise en page ne plante pas : elle dessine quelque chose de
plausible qui ment sur les proportions, exactement le défaut que ce programme
existe pour éviter. `--self-test-layout` vérifie, sur l'arbre réel et dans les
cinq mesures, que les enfants tiennent dans leur cadre, le remplissent à 1 %
près, ne se chevauchent pas, et que la surface de chacun vaut sa part de la
valeur. Sur un dossier personnel : 40 000 rectangles, erreur de proportion
0,0000, rapport largeur/hauteur médian 1,12.

## Ce qui a bougé

La question qu'on se pose n'est presque jamais « qu'est-ce qui est gros » — on
le sait déjà. C'est « qu'est-ce qui a mangé quarante gigaoctets cette
semaine ». Un treemap statique est une photo et n'y répond pas.

```
$ cadastre ~/projet --since last

ÉCART  ~/projet
  du 10 sept. 09:14 au 17 sept. 15:28  (7 j 6 h)

    attributed     47.2 MB  →     105 MB    +57.7 MB

  OÙ ÇA A BOUGÉ  (variation propre au dossier)
           +52.4 MB  ~/projet/build
           -21.0 MB  ~/projet/assets  rien d'écrit — part de blocs partagés redistribuée
  neuf     +18.9 MB  ~/projet/node_modules
```

Les arbres sont appariés par nom, niveau par niveau — aucun chemin n'est
construit pour l'appariement, la comparaison est linéaire. Deux arbres de
262 000 nœuds se comparent en 68 ms, processus compris.

### « rien d'écrit »

Cloner un fichier dans un autre dossier divise par deux la part créditée à
l'original. Un dossier auquel personne n'a touché peut donc *rétrécir*. Le diff
mesure en parallèle la variation de `allocated` — les octets réellement
écrits — et signale les lignes où le contenu n'a pas bougé et où seule la
comptabilité s'est déplacée. Sans ça le rapport est exact et trompeur. La carte
en mode **Par ce qui a changé** colore d'ailleurs les octets écrits, pas la
mesure affichée, pour la même raison.

### Les repères

`⌘S` dans l'app, `--save auto` en ligne de commande : l'état du dossier est
écrit dans l'historique local. Plus tard, le menu « comparer à » propose les
repères posés sur ce même dossier.

Ils sont datés par l'heure du **scan**, lue dans leur nom de fichier, et non par
la date de modification du fichier : un repère posé dix minutes après coup
désignerait sinon un instant qui n'est pas celui qu'il contient — et une
session s'offrirait son propre repère comme point de comparaison.

`CADASTRE_HOME` déplace l'historique ailleurs que
`~/Library/Application Support/Cadastre`.

### L'index

Un scan enregistré est un fichier binaire plat : en-tête, enregistrements à
largeur fixe, une arène de noms. Le JSON était tentant et c'est la mauvaise
forme — quelques millions de nœuds coûtent plus cher à relire que le scan à
refaire. Seules les tailles *propres* à chaque nœud sont stockées ; les totaux
de sous-arbre sont recalculés au chargement, ce qui évite qu'ils divergent.

220 000 fichiers et 42 000 dossiers tiennent dans 22 Mo, relus en 68 ms.

## Sûr à supprimer

Le principe de ce catalogue est qu'**un nom ne suffit jamais**. `build` est la
sortie d'un compilateur dans un projet et dix ans de travail dans un autre.
Chaque règle exige donc une preuve — un `package.json` à côté de
`node_modules`, un `Cargo.toml` à côté de `target`, un `CMakeCache.txt` dans
`build` — et un dossier qui ne peut pas la produire n'est pas proposé. Être
inutile se rattrape, se tromper non.

Trois niveaux, et le troisième n'est jamais supprimé par le programme :

| | |
|---|---|
| `REGÉNÉRABLE` | reconstruit par un outil à partir de fichiers toujours présents |
| `CACHE` | se reremplit tout seul — on perd du temps, pas des données |
| `À VOTRE APPRÉCIATION` | volumineux et souvent inutile, mais irremplaçable : sauvegardes iOS, archives Xcode, corbeille |

Gardes appliquées à chaque candidat, au moment du rapport **et** à nouveau
juste avant la suppression, parce qu'un scan est une photo et que le disque
continue de bouger :

- jamais un lien symbolique
- jamais un dossier contenant un `.git` — un arbre de travail n'est pas une sortie de compilation
- jamais sous `/System`, `/usr`, `/bin`, `/Applications`, `/private/var/db`…
- jamais un candidat imbriqué dans un autre (sinon tout est compté deux fois)
- suppression vers la **corbeille**, jamais `unlink` : ces règles sont des
  heuristiques, et une heuristique a besoin d'un retour en arrière

### Le gain n'est pas la somme des parties

pnpm lie en dur les dépendances de tous les projets vers un magasin commun.
Supprimer un seul `node_modules` ne libère presque rien ; les supprimer tous
libère beaucoup. Cadastre calcule le gain de l'**ensemble** sélectionné, pas la
somme des gains individuels :

```
     4.19 MB  projA/node_modules   · 15.7 MB partagés hors de ce dossier
         0 B  projB/node_modules   · 15.7 MB partagés hors de ce dossier

  TOTAL RÉCUPÉRABLE  56.6 MB
  soit 31.5 MB de plus qu'en les supprimant un par un
```

`⌘R` ouvre le même catalogue en liste cochable, et le total du bas se recalcule
à chaque case : c'est pour ça que cocher une deuxième case peut libérer plus
que ce que cette case vaut seule.

Et s'il existe un snapshot local, le rapport le dit : l'espace ne reviendra
qu'à son expiration, quoi qu'on supprime.

## Vitesse

`getattrlistbulk(2)` ramène le nom *et* tous les attributs de taille pour
quelques centaines d'entrées par appel. Le `readdir` + `lstat` par fichier des
outils classiques coûte un syscall par fichier.

~262 000 entrées en 2,1 s sur SSD interne (≈ 120 000 entrées/s, 8 threads),
2,3 s avec un enregistrement par fichier conservé et l'index écrit.

## Deux langues, un seul binaire

Il n'y a pas de bundle de ressources à chercher : le programme est un binaire
unique, qui est à la fois l'application et l'outil en ligne de commande, et un
lancement depuis le terminal n'a aucun `.lproj` sous la main. Chaque chaîne
visible est donc écrite sur place, dans les deux langues, par `tr(en:fr:)` —
l'anglais d'abord, le français ensuite, partout. C'est plus verbeux qu'une
table de clés, et bien plus difficile à laisser une chaîne non traduite.

La langue est choisie dans cet ordre : `--lang`, puis `CADASTRE_LANG`, puis la
préférence posée depuis le menu de l'application, puis la langue du système.
Les unités suivent : « 6,3 Go » en français, "6.3 GB" en anglais, comme le
Finder. Les descriptions des demandes d'accès (Bureau, Documents…) sont les
seules chaînes hors du binaire : macOS les lit dans `InfoPlist.strings`, que
`bundle.sh` écrit dans les deux langues.

## Notes d'interface

Les deux menus de la barre d'outils ne sont pas nommés d'après le code : la
mesure affichée est rappelée en toutes lettres au bas de la fenêtre
(« Surface des rectangles · Occupation réelle — part équitable des blocs
partagés… »), et la légende est précédée de ce qu'elle légende
(« Couleur · Par type de fichier — »). Un menu qui affiche `attributed` à côté
d'`exclusive` n'explique rien à qui n'a pas lu les sources.

La fenêtre est un `NSSplitViewController` : barre d'outils unifiée dans la
barre de titre, inspecteur vitré à droite, carte au centre. La première version
empilait barre de titre, bande de contrôles et fil d'Ariane — trois bandes de
chrome au-dessus de la chose qu'on venait regarder.

Dans l'inspecteur, les valeurs sont posées sur une tabulation à droite et
groupées sous des en-têtes discrets. Avant, chaque chiffre suivait son libellé :
exact, et illisible d'un coup d'œil. Le champ recalcule sa largeur de ligne à
chaque disposition : un `NSTextField` ordinaire annonce la largeur de sa chaîne
entière comme taille intrinsèque, et un nom de fichier long élargissait le
panneau à chaque survol.

Le test de survol renvoie directement l'indice trouvé, au lieu de rebalayer les
quarante mille rectangles pour retrouver ce que la recherche avait déjà en main.
C'était du travail redondant ; je n'ai pas mesuré de différence perceptible.

La sélection au clavier est un anneau de la couleur d'accentuation, distinct du
survol : le pointeur et les flèches peuvent désigner deux choses. Les flèches
choisissent le voisin *par position à l'écran* parmi les frères, pas par rang
dans une liste — ce qui est à droite de la sélection est ce que l'œil s'attend
à atteindre avec `→`.

La recherche ne filtre pas, elle éteint : les rectangles qui ne correspondent
pas se fondent dans la surface, ceux qui correspondent gardent leur couleur, et
un dossier dont le nom correspond allume tout ce qu'il contient. Le pied de
fenêtre donne le compte et le total des correspondances de premier niveau — un
dossier qui correspond et les fichiers qu'il contient font un seul total, pas
deux.

Le cadre racine n'a pas de bandeau de titre : son nom est déjà dans le fil
d'Ariane, et son cadre est la fenêtre. La première version l'affichait deux
fois.

Un scan interrompu est affiché tel quel, marqué « partiel » en orange dans le
pied de fenêtre, et un dossier refusé pour manque de permission l'est de la
même façon. Un total incomplet annoncé comme complet est exactement le mensonge
que ce programme existe pour éviter ; un plancher annoncé comme plancher n'en
est pas un.

## Structure

```
Package.swift            cible C + exécutable, macOS 14
Sources/CadastreC/
  include/CadastreC.h    interface : politiques d'E/S, décodage bulk
  bulk.c                 getattrlistbulk, décodage du buffer packé
Sources/cadastre/
  L10n.swift             les deux langues : tr(en:fr:), unités, dates, préférence
  Tree.swift             arbre en struct-of-arrays, LCA, remontée, table des fichiers
  Families.swift         clones et liens durs : qui possède quels blocs
  Walker.swift           parcours parallèle, interruptible
  Index.swift            format binaire, historique local
  Diff.swift             appariement de deux scans
  Reclaim.swift          catalogue à preuve, gardes, mise à la corbeille
  VolumeReport.swift     conteneur, snapshots, purgeable, TCC
  Format.swift           rendu terminal
  main.swift             CLI, exports JSON
Sources/cadastre/UI/
  Treemap.swift          modèle aplati, fusion des chaînes à enfant unique
  TreemapLayout.swift    squarified (Bruls, Huizing, van Wijk 2000)
  LayoutSelfTest.swift   invariants de géométrie
  Palette.swift          palette cherchée, et le raisonnement qui a fixé sa taille
  TreemapRenderer.swift  rectangles instanciés en Metal
  TreemapView.swift      survol, sélection, clavier, recherche, zoom animé, menu contextuel
  LabelPass.swift        étiquettes, encre choisie par contraste mesuré
  Legend.swift           légende permanente, légendée
  Window.swift           fenêtre, barre d'outils, menus, fil d'Ariane, inspecteur, état vide
  Session.swift          dossier analysé, repères, scan en arrière-plan, dossiers récents
  ReclaimSheet.swift     catalogue cochable, gain combiné, re-vérification
  Snapshot.swift         export PNG hors écran
  Icon.swift             icône, pavée par le même algorithme que la carte
Scripts/
  verify.sh              vérité terrain : chaque cas a une réponse connue par construction
  bundle.sh              construit Cadastre.app (signature ad hoc)
```

`Scripts/verify.sh` construit de vrais fichiers sur un vrai volume APFS — ces
nombres viennent du système de fichiers, ils ne peuvent pas être testés à
sec — et vérifie entre autres que `allocated` reproduit `du` exactement, que la
géométrie du treemap est exacte au 1 % près, et que le bundle se construit.

## Reste à faire

- `--watch` : rafraîchissement incrémental par FSEvents plutôt qu'un rescan
- Élargir le catalogue (Docker.raw, qui relève d'un conseil `docker system
  prune` plutôt que d'une suppression ; Mail Downloads ; caches Homebrew)
- Changer de langue sans relancer : chaque contrôle a été construit avec la
  langue précédente, et les reconstruire tous à chaud n'a pas encore été jugé
  valoir le code que ça coûte
- La signature est ad hoc : l'app tourne sur cette machine, elle n'est pas
  distribuable telle quelle
