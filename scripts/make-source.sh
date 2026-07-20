#!/bin/bash
# Genera source.json (source de SideStore/AltStore) para una versión dada.
# Uso: ./scripts/make-source.sh v1.0.1 <tamaño_ipa_bytes> "descripción de la versión"
set -euo pipefail

TAG="${1:?tag (ej. v1.0.1)}"
SIZE="${2:?tamaño del IPA en bytes}"
DESC="${3:-Mejoras y correcciones.}"
VERSION="${TAG#v}"
DATE="$(date -u +%Y-%m-%d)"
REPO="sebastianov92/crona"
DOWNLOAD="https://github.com/$REPO/releases/download/$TAG/Crona.ipa"
ICON="https://raw.githubusercontent.com/$REPO/main/docs/icon.png"

cat > "$(dirname "$0")/../source.json" <<EOF
{
  "name": "Crona",
  "identifier": "com.sebastian.crona.source",
  "subtitle": "Programa mensajes de WhatsApp",
  "iconURL": "$ICON",
  "website": "https://github.com/$REPO",
  "tintColor": "#25D366",
  "apps": [
    {
      "name": "Crona",
      "bundleIdentifier": "com.sebastian.crona",
      "developerName": "Sebastián Ordóñez",
      "subtitle": "Programa mensajes de WhatsApp",
      "localizedDescription": "Programa mensajes de WhatsApp (texto, fotos, videos y PDF) para que se envíen solos, con recurrencias, múltiples destinatarios y respuestas automáticas. Requiere tu propio servidor Crona (ver GitHub).",
      "iconURL": "$ICON",
      "tintColor": "#25D366",
      "category": "utilities",
      "screenshots": [],
      "versions": [
        {
          "version": "$VERSION",
          "date": "$DATE",
          "size": $SIZE,
          "downloadURL": "$DOWNLOAD",
          "localizedDescription": "$DESC",
          "minOSVersion": "17.0"
        }
      ],
      "appPermissions": {
        "entitlements": ["com.apple.security.application-groups"],
        "privacy": {}
      }
    }
  ],
  "news": []
}
EOF
echo "source.json → $VERSION ($SIZE bytes)"
