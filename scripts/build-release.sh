#!/bin/bash
# Construye artefactos distribuibles de Crona:
#   dist/Crona.dmg  — app macOS con firma ad-hoc (click derecho → Abrir la 1ª vez)
#   dist/Crona.ipa  — app iOS SIN firmar (instalar con Sideloadly/AltStore + Apple ID propio)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"   # en CI viene del tag (vX.Y.Z)
APP_DIR="$ROOT/apps/Crona"
DIST="$ROOT/dist"
DD="$(mktemp -d)/dd"

command -v xcodegen >/dev/null || { echo "falta xcodegen (brew install xcodegen)"; exit 1; }

rm -rf "$DIST" && mkdir -p "$DIST"
cd "$APP_DIR"
xcodegen generate >/dev/null

echo "── macOS (Release, firma ad-hoc) ──"
xcodebuild -project Crona.xcodeproj -scheme Crona -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DD" \
  MARKETING_VERSION="$VERSION" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  build | grep -E "error:|BUILD" || true

MAC_APP="$DD/Build/Products/Release/Crona.app"
[ -d "$MAC_APP" ] || { echo "build macOS falló"; exit 1; }

STAGE="$(mktemp -d)/Crona"
mkdir -p "$STAGE"
cp -R "$MAC_APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Crona" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Crona.dmg" >/dev/null
echo "→ $DIST/Crona.dmg"

echo "── iOS (Release, sin firmar) ──"
xcodebuild -project Crona.xcodeproj -scheme Crona -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  MARKETING_VERSION="$VERSION" CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD" || true

IOS_APP="$DD/Build/Products/Release-iphoneos/Crona.app"
[ -d "$IOS_APP" ] || { echo "build iOS falló"; exit 1; }

PAYLOAD="$(mktemp -d)/Payload"
mkdir -p "$PAYLOAD"
cp -R "$IOS_APP" "$PAYLOAD/"
(cd "$(dirname "$PAYLOAD")" && zip -qry "$DIST/Crona.ipa" Payload)
echo "→ $DIST/Crona.ipa"

echo "── listo ──"
ls -lh "$DIST"
