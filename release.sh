#!/bin/bash
# Publie la version courante (Resources/Info.plist) : compile, signe Developer ID, notarise, agrafe, archive,
# crée la release GitHub vX.Y.Z. L'appli installée se met à jour toute seule depuis cette release (App/Updater.swift).
# Usage : ./release.sh   (notes : _tools/changelogs/qLOOKS_<version>.txt, 4 langues obligatoires)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Modifications non commitées : commitez d'abord." >&2; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1 && [ -z "${REPUBLISH:-}" ]; then echo "$TAG existe déjà : changez la version dans Resources/Info.plist (ou REPUBLISH=1 pour remplacer cette release)." >&2; exit 1; fi

WORK="$(mktemp -d)"
PUBLIC=1 NO_INSTALL=1 ./build_app.sh
DIST="$WORK/notarized" /Volumes/SKYRIM/TOOLS/MAC/_tools/notarize_app.sh "$HOME/Library/Caches/qLOOKS-build/qLOOKS.app"
ZIP="$WORK/qLOOKS-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$WORK/notarized/qLOOKS.app" "$ZIP"
(cd "$WORK" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
python3 /Volumes/SKYRIM/TOOLS/MAC/_tools/release_notes.py qLOOKS "$VERSION" --sha "$ZIP.sha256" -o "$WORK/notes.md"
git push origin main
if [ -n "${REPUBLISH:-}" ]; then
  gh release upload "$TAG" "$ZIP" "$ZIP.sha256" --clobber
  gh release edit "$TAG" --notes-file "$WORK/notes.md"
else
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "qLOOKS $VERSION" --notes-file "$WORK/notes.md"
fi
rm -rf "$WORK"
echo "OK : release $TAG publiée"
