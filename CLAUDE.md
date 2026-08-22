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
- **Reconcile** : fast-path si `onScreen` inchangé ; passes de confirmation (+0.3/+0.8s) pour les fenêtres qui matérialisent tard ; **jamais** de `CGWindowList` en boucle sur le timer (tue l'App Nap).
- **Restore au lancement** : restaurer **TOUTES** les workspaces d'un coup depuis un pool partagé (sinon la 1re visitée avale les fenêtres des autres).
- **`setCocoaFrame`** cache `lastSetFrame` **uniquement si l'écriture AX a réussi** (sinon la prochaine render ré-émet).
- **Notch (laptop seul)** : `layoutRect` réserve `Config.notchBarOffset` (défaut 40) quand `screens.count==1 && safeAreaInsets.top>0` — **doit matcher** le `y_offset` de la sketchybar (config externe de l'utilisateur, hors repo).

## Conventions
- **Self-tests verts** obligatoires ; garder `parkRect`/`monitorBlock`/`previewFrames` **pures + unit-testées** (ajouter un test avec toute nouvelle logique géométrique).
- Commits : **PAS de trailer `Co-Authored-By`**. Style de code : coller au fichier (densité de commentaires, nommage, idiomes existants — les commentaires expliquent le *pourquoi* des pièges).
- Pas de dépendance CGS/Spaces réintroduite dans v2 (le pivot l'a justement supprimée).

## Pointeurs
- `README.md` (vue d'ensemble), `CHEATSHEET.md` (raccourcis + config), `docs/V2-EMULATED-WORKSPACES.md` (leçons AeroSpace + milestones + ce qui survit/change).
