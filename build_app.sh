#!/bin/zsh
# Construit « qLOOKS.app » et ses deux extensions QuickLook (aperçu, vignettes), signe le tout (extensions d'abord,
# avec leurs droits de sandbox), installe dans ~/Applications/Applications Personnelles et enregistre les extensions.
# NO_INSTALL=1 : ne pas installer. Aucune fenêtre n'est ouverte.
set -euo pipefail
cd "$(dirname "$0")"
SRC="$PWD"
WORK="$HOME/Library/Caches/qLOOKS-build"   # disque local : un volume externe ajoute des métadonnées qui font échouer codesign
APP="$WORK/qLOOKS.app"
DEST="$HOME/Applications/Applications Personnelles"
SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
TARGET="arm64-apple-macos15"
SWIFTC=(swiftc -O -swift-version 5 -target "$TARGET")

rm -rf "$WORK"; mkdir -p "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Appli hôte
"${SWIFTC[@]}" -parse-as-library -module-name qLOOKS -o "$APP/Contents/MacOS/qLOOKS" App/*.swift Shared/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Extensions : point d'entrée _NSExtensionMain, code limité aux API autorisées dans une extension.
build_ext() {
  local name="$1" fw="$2"; shift 2
  local ext="$APP/Contents/PlugIns/$name.appex"
  mkdir -p "$ext/Contents/MacOS"
  "${SWIFTC[@]}" -parse-as-library -application-extension -module-name "$name" -framework "$fw" \
    -Xlinker -e -Xlinker _NSExtensionMain -o "$ext/Contents/MacOS/$name" "$@" Shared/*.swift
  cp "Resources/$name-Info.plist" "$ext/Contents/Info.plist"
  SIGN_ENTITLEMENTS="$PWD/Resources/Extension.entitlements" SIGN_NO_DEEP=1 "$SIGN" "$ext"
}
build_ext Preview QuickLookUI Preview/*.swift
build_ext Thumbnail QuickLookThumbnailing Thumbnail/*.swift

# Décodeur vidéo (MediaExtension, ExtensionKit) : PNG et Animation pour tout macOS. Exige le profil de provisionnement.
if [ -f Resources/Decoder.provisionprofile ]; then
  DEC="$APP/Contents/Extensions/Decoder.appex"
  mkdir -p "$DEC/Contents/MacOS"
  "${SWIFTC[@]}" -parse-as-library -application-extension -module-name Decoder -framework MediaExtension -framework ExtensionFoundation \
    -Xlinker -e -Xlinker _EXExtensionMain -o "$DEC/Contents/MacOS/Decoder" Decoder/Decoder.swift Shared/QTRLE.swift
  cp Resources/Decoder-Info.plist "$DEC/Contents/Info.plist"
  cp Resources/Decoder.provisionprofile "$DEC/Contents/embedded.provisionprofile"
  SIGN_ENTITLEMENTS="$PWD/Resources/Decoder.entitlements" SIGN_NO_DEEP=1 "$SIGN" "$DEC"
fi

SIGN_ENTITLEMENTS="$PWD/Resources/App.entitlements" SIGN_NO_DEEP=1 "$SIGN" "$APP"

if [ -z "${NO_INSTALL:-}" ]; then
  mkdir -p "$DEST"
  pkill -x qLOOKS 2>/dev/null || true
  rm -rf "$DEST/qLOOKS.app"
  ditto --norsrc --noextattr "$APP" "$DEST/qLOOKS.app"
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -f -R "$DEST/qLOOKS.app"
  pluginkit -a "$DEST/qLOOKS.app/Contents/PlugIns/Preview.appex"
  pluginkit -a "$DEST/qLOOKS.app/Contents/PlugIns/Thumbnail.appex"
  [ -d "$DEST/qLOOKS.app/Contents/Extensions/Decoder.appex" ] && pluginkit -a "$DEST/qLOOKS.app/Contents/Extensions/Decoder.appex"
  sleep 2
  # Sans ce choix explicite, le lecteur intégré de macOS garde la priorité pour les .mov ; il est perdu à chaque réinstallation.
  pluginkit -e use -i fr.stephan.alphalook.preview
  pluginkit -e use -i fr.stephan.alphalook.thumbnail
  pluginkit -e use -i fr.stephan.alphalook.decoder
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  echo "Installée : $DEST/qLOOKS.app"
fi
echo "OK : $APP"
