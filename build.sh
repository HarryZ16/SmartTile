#!/bin/bash
# Builds SmartTile and packages it as SmartTile.app
#   ./build.sh            build into build/SmartTile.app
#   ./build.sh --install  build, install to /Applications and launch
#   ./build.sh --reset    also reset the Accessibility permission (first time after a
#                         signing change, or when the permission stops working)
#   ./build.sh --test     run the unit tests first
#   ./build.sh --adhoc    skip the self-signed certificate and sign ad-hoc (used by CI)
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
RESET=0
TEST=0
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --reset) RESET=1 ;;
    --test) TEST=1 ;;
    --adhoc) ADHOC=1 ;;
  esac
done

IDENTITY="SmartTile Dev"
BUNDLE_ID="com.harry.smarttile"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found. Install the command line tools first: xcode-select --install"
  exit 1
fi

if [ "$TEST" = "1" ]; then
  echo "==> Running unit tests"
  swift test
fi

echo "==> Building (release)"
swift build -c release

APP="build/SmartTile.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/SmartTile" "$APP/Contents/MacOS/SmartTile"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Localizations (en.lproj, zh-Hans.lproj, ...)
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"
done

# Sign with a fixed self-signed certificate. As long as the signature stays the same,
# macOS doesn't ask for the Accessibility permission again after every rebuild.
create_identity() {
  echo "==> First run: creating a local code-signing certificate \"$IDENTITY\" in your login keychain"
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/id.p12" -passout pass:smarttile >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P smarttile -T /usr/bin/codesign >/dev/null || { rm -rf "$tmp"; return 1; }
  echo "    (macOS may ask for your login password to trust the certificate; cancelling is fine too)"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  echo "    Certificate created. Re-grant permission once after switching signatures: ./build.sh --install --reset"
}

echo "==> Signing"
SIGNED=0
if [ "$ADHOC" = "1" ]; then
  echo "    --adhoc: skipping the self-signed certificate"
elif ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  create_identity || echo "    Could not create the certificate; falling back to ad-hoc signing"
fi
if [ "$ADHOC" = "0" ] && security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "    (if asked whether codesign may access your keychain, choose \"Always Allow\")"
  if codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP" 2>build/sign.log; then
    SIGNED=1
    echo "    Signed with \"$IDENTITY\""
  else
    echo "    Self-signing failed (see build/sign.log); falling back to ad-hoc signing"
  fi
fi
if [ "$SIGNED" = "0" ]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  echo "    Ad-hoc signed: after each rebuild run ./build.sh --install --reset and grant permission again"
fi

if [ "$RESET" = "1" ]; then
  echo "==> Resetting Accessibility permission"
  tccutil reset Accessibility "$BUNDLE_ID" || true
fi

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  pkill -x SmartTile 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/SmartTile.app"
  cp -R "$APP" "/Applications/SmartTile.app"
  open "/Applications/SmartTile.app"
  echo "Done: SmartTile is running (look for its icon in the menu bar)"
else
  echo "Done: $APP"
  echo "Run: open $APP"
fi
