# Mosaic — guide contributeur (Claude)

Tiling/tabbing window manager pour macOS, en Swift (SwiftPM), **SIP activé → Accessibility (AX) uniquement**, pas d'API privée qui exige SIP-off.

## Build / test / run
- **Valider la logique** : `make test` → build debug + `.build/debug/Mosaic --self-test` (suite de tests purs : arbre de layout + parsing config). **Doit rester VERT à chaque changement.**
- **Produire l'app** : `make bundle` → build release + `Mosaic.app` signé avec l'identité stable « Mosaic Self-Signed » (bundle id `fr.rgouttiere.mosaic` → conserve le grant Accessibilité entre rebuilds). `make run` = bundle + lance.
- Itérer vite : `swift build` compile ; `swift run Mosaic --self-test` marche aussi.
- Config live de l'utilisateur : `~/.config/mosaic/config.json` (hot-reload via file-watch) ; état : `~/.config/mosaic/state.json` ; diag : action `dump-layout` → `/tmp/mosaic-dump.txt`.

## Branches
- `main` = v0.5.x **stable** (Spaces macOS réels), daily-driver — **ne pas casser**.
- `v2-emulated` = travail courant : **workspaces émulés** (voir `docs/V2-EMULATED-WORKSPACES.md`).

## Architecture (v2 émulé)
Un **seul** Space macOS. Un « workspace » = ensemble logique de fenêtres. Switch = **park** (déplacer hors écran) / **unpark** (à l'écran) via `Container.arrange(in:)`. `shownOnDisplay: [displayID: workspace]` est **possédé par nous** (jamais lu du window-server). **Model A** : workspaces 1-9 globales, chacune épinglée à un moniteur (`assignedDisplay` / `WindowManager.monitorBlock`, pures + testées). Cœur = arbre `Container` (splits / tabbed / stacked), intact depuis v1.

## Invariants load-bearing (coûteux à re-découvrir)
- **Z-order par couche d'APP** : macOS empile par app d'abord ; `AX.raise` (kAXRaiseAction) ne réordonne que *dans* une app. Pour passer une app au-dessus d'une autre → **`NSRunningApplication.activate()`** (cf. `liftAppsAboveParked`, appelé au switch sur les workspaces multi-apps).
- **Ne JAMAIS `AX.raise` une fenêtre fullscreen native** : ça tire son Space au premier plan de façon incontrôlée.
- **Park géométrie** (`Geometry.parkRect`, pure + testée) : pousser hors du bord **du moniteur d'attache** qui donne sur le vide (le plus à droite→droite, à gauche→gauche, **intérieur→bas**). Jamais en **coin** (macOS shrink la hauteur → fenêtres qui reviennent raccourcies). Jamais cross-résolution (sinon clamp → resize).
- **`screen(forWorkspace:)` = 3 conditions** : `spaces[n]` existe + `ws.displayID != 0` + `shownOnDisplay[did] == n`. Au **dock**, `ensureAllPresentMonitorsShown` doit re-homer **tous** les moniteurs présents (pas que celui sous la souris), sinon écrans vides.
- **Reconcile** : fast-path si `onScreen` inchangé ; passes de confirmation (+0.3/+0.8s) pour les fenêtres qui matérialisent tard ; **jamais** de `CGWindowList` en boucle sur le timer (tue l'App Nap) — garde-fou à vérifier sur **multi-écrans**, celui de `purgeVisibleGhosts` ne se fermait jamais à 3 moniteurs et tournait donc à plein régime en permanence.
- **Restore au lancement** : restaurer **TOUTES** les workspaces d'un coup depuis un pool partagé (sinon la 1re visitée avale les fenêtres des autres).
- **`setCocoaFrame`** cache `lastSetFrame` **uniquement si l'écriture AX a réussi** (sinon la prochaine render ré-émet).
- **Tuiles disjointes** : deux tuiles ne se chevauchent jamais, donc leur ordre de profondeur est invisible. Le seul empilement qui compte est **dans un groupe d'onglets**. Une passe qui remonte « toutes les fenêtres visibles » à chaque render est du cross-process pour rien (`raiseOutOfOrderTabs` ne remonte que les groupes réellement mal empilés, en lisant l'instantané ordonné avant→arrière).
- **Jamais deux écritures de frame sur la même fenêtre dans un render** : `arrange` plaçait chaque onglet caché sur sa tuile et `parkHiddenCrossAppTabs` le repoussait juste après — chacune défaisait l'autre, donc le cache `lastSetFrame` ne sautait **jamais**. Le park est seul écrivain (`Container.parkedOffScreen`), libéré pour l'onglet qui devient sélectionné et pour un groupe qui cesse de qualifier.
- **`ManagedWindow.frame` est caché 50 ms** : plusieurs passes d'un render relisent la même fenêtre (letterbox, bordures, halo, aspect-fit) et chaque lecture est un aller-retour dans l'app. Sans ça le coût d'un render est fixé par l'app la plus lente de la disposition, pas par ce qu'il y a à dessiner (IINA : `decorate` 6 → 116 ms). Toute écriture invalide ; la relecture dans `setCocoaFrame` **alimente** le cache au lieu de le contourner.
- **Une seule énumération `CGWindowList` par render** : `onScreenSnapshot` (TTL court), invalidé par le reconcile dès que le jeu de fenêtres change. Deux appels coûtaient ~3 ms chacun.
- **Minimum de resize plafonné** à `Geometry.maxLearnedMinShare` (0,45) de la paire : à 1/2 les deux minimums se rejoignent, `lo == hi`, et le séparateur gèle jusqu'au redémarrage. Ne jamais apprendre un minimum d'une fenêtre **fullscreen** ou sous **monocle** — elles rapportent l'écran entier.
- **Jeu en plein écran fenêtré** : subrole `AXUnknown`, `AXFullScreen=false`, et le clamp AX laisse ~40 px à l'écran donc `cgOnScreen` reste `true`. Le yield se décide sur **l'app au premier plan**, jamais sur le z-order : Mosaic remonte ses propres tuiles à chaque render, donc un test de z-order se désactiverait lui-même définitivement.
- **`status.json`** : ne pas republier un contenu identique. Chaque écriture réveille ce qui le surveille, et une barre externe qui redessine ses pastilles ne distingue pas une ré-émission d'un vrai changement.
- **Notch (laptop seul)** : `layoutRect` réserve `Config.notchBarOffset` (défaut 40) quand `screens.count==1 && safeAreaInsets.top>0` — **doit matcher** le `y_offset` de la sketchybar (config externe de l'utilisateur, hors repo).

## Veille / réveil (le plus cher à re-découvrir)
- `handleWake` est branché sur **deux** notifications (`didWake` + `screensDidWake`) : une seule veille déclenche la séquence deux fois. Étapes en `DispatchWorkItem` annulables, annulées à l'entrée (la 2e notification se fond dans la 1re) et à chaque veille.
- **`suspended` = ensemble de raisons** (`SuspendReason`), chacun ne relâche que la sienne. En booléen partagé, un changement d'écran qui se stabilisait pendant une veille levait la suspension **de la veille**, et le reconcile repartait sur des fenêtres endormies.
- Toute étape différée capture `sleepGeneration`, incrémentée à chaque veille : sinon un relâchement programmé avant une nouvelle veille atterrit dedans et réveille une machine endormie.
- **Ne rien re-dériver tant que les écrans ne sont pas tous revenus** : `assignedDisplay` mappe par **index** gauche→droite, donc avec un seul écran présent tous les workspaces s'y résolvent. Publier ces états transitoires redistribue le bureau plusieurs fois par seconde (et fait recharger la barre externe). `handleDisplayChange` force après 1,5 s de stabilité — c'est ce qui distingue un ensemble réduit *réel* d'un ensemble en train de se remplir.
- **L'absence d'une fenêtre de l'énumération AX n'est pas une preuve de fermeture.** Pendant `wakeGraceUntil` (30 s), 25 ratés au lieu de 2 — dans `reconcile` **et** dans `purgeVisibleGhosts`, qui possède les moniteurs visibles non actifs et était le chemin par lequel une veille longue redistribuait une disposition entière.
- Une feuille détachée note son workspace (`rememberReturn`) : la fenêtre qui revient y retourne au lieu d'atterrir dans le workspace actif. Consulté **après** les hints de relance, pour qu'un vrai redémarrage d'app garde la priorité.
- **`state.json.prev`** : point de restauration décalé de 5 min. Les sauvegardes tournent en continu, donc quand on constate qu'une disposition est cassée la bonne version est écrasée depuis longtemps. `cp state.json.prev state.json` Mosaic arrêté, puis relancer.

## Conventions
- **Self-tests verts** obligatoires ; garder `parkRect`/`monitorBlock`/`previewFrames`/`resizeLimits`/`covers` **pures + unit-testées** (ajouter un test avec toute nouvelle logique géométrique).
- Commits : **PAS de trailer `Co-Authored-By`**. Style de code : coller au fichier (densité de commentaires, nommage, idiomes existants — les commentaires expliquent le *pourquoi* des pièges).
- Pas de dépendance CGS/Spaces réintroduite dans v2 (le pivot l'a justement supprimée).

## Pointeurs
- `README.md` (vue d'ensemble), `CHEATSHEET.md` (raccourcis + config), `docs/V2-EMULATED-WORKSPACES.md` (leçons AeroSpace + milestones + ce qui survit/change).
