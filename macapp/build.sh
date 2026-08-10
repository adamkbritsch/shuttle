#!/bin/bash
# Build "Shuttle.app" — a native SwiftUI client for the seedbox->NAS relay's HTTP
# API on the NAS.
#
#   ./build.sh                     build only, into dist/
#   ./build.sh --install           build, then install to ~/Applications
#   ./build.sh --release [X.Y.Z]   stamp the version, build, and zip for a
#                                  GitHub Release into dist/Shuttle-vX.Y.Z.zip
#
# No Xcode project required — plain swiftc plus a hand-assembled bundle, matching the
# two sibling apps. (Xcode.app IS used for one thing: actool, to compile the Icon
# Composer icon. Absent, the build still succeeds without a custom icon.)
set -euo pipefail

ROOT="${SHUTTLE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$ROOT/macapp"
DIST="$ROOT/dist"
APP="$DIST/Shuttle.app"
INSTALLED="${SHUTTLE_INSTALL_PATH:-$HOME/Applications/Shuttle.app}"
BUNDLE_ID="${SHUTTLE_BUNDLE_ID:-com.britsch.shuttle}"
EXEC_NAME="Shuttle"
VERSION="1.0.0"

# --release [version]: stamp the bundle with this version and produce the zip a
# GitHub Release attaches. Parsed before anything else so VERSION is right by the
# time Info.plist is written.
RELEASE=0
if [[ "${1:-}" == "--release" ]]; then
  RELEASE=1
  [[ -n "${2:-}" ]] && VERSION="${2#v}"
fi
# Optional. Bakes a default relay address into the build so a fresh install
# opens already pointing at your NAS; otherwise set it in Settings.
RELAY_HOST="${SHUTTLE_RELAY_HOST:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Compile everything to a temp path first. A build error must never be able to
#    leave a half-written bundle behind.
# Build against Xcode's SDK, not the Command Line Tools' one.
#
# `xcode-select -p` points at CommandLineTools here, so a bare `swiftc` links
# against SDK 15.5 and the binary records `sdk 15.5`. On macOS 26 the LINKED SDK
# version is what decides whether AppKit hands you the current control shapes — so
# every button, field, segmented control, menu, sheet and scroller was drawing in
# the previous shape language.
#
# The -Xlinker -platform_version line is NOT optional: without it the binary records
# `sdk 14.0` and the whole exercise is a no-op. Xcode passes it automatically; a
# hand-rolled swiftc does not.
#
# Deployment target and linked SDK are independent: LSMinimumSystemVersion stays at
# 14.0 and the sources still compile at -target arm64-apple-macosx14.0.
DEVDIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SWIFTC="$DEVDIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="$DEVDIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ -x "$SWIFTC" && -d "$SDK" ]]; then
  SDKVER="$(/usr/bin/plutil -extract Version raw "$SDK/SDKSettings.plist" 2>/dev/null || echo "")"
  if [[ -n "$SDKVER" ]]; then
    SDKARGS=(-sdk "$SDK" -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDKVER")
    echo "==> Using Xcode SDK $SDKVER"
  else
    SDKARGS=(-sdk "$SDK")
  fi
else
  echo "==> Xcode not found; using CLT swiftc (pre-Tahoe control appearance)"
  SWIFTC=swiftc; SDKARGS=()
fi

echo "==> Compiling"
"$SWIFTC" -target arm64-apple-macosx14.0 -O "${SDKARGS[@]}" \
  "$SRC"/main.swift "$SRC"/Theme.swift "$SRC"/Token.swift \
  "$SRC"/Models.swift "$SRC"/API.swift \
  "$SRC"/Backend.swift "$SRC"/LocalBackend.swift \
  "$SRC"/LocalTransfers.swift "$SRC"/Store.swift \
  "$SRC"/SplitTree.swift "$SRC"/DirTree.swift "$SRC"/FileTable.swift \
  "$SRC"/Setup.swift "$SRC"/BulkRename.swift "$SRC"/Search.swift "$SRC"/ConflictSheet.swift "$SRC"/BrowsePane.swift "$SRC"/Transfers.swift "$SRC"/RootView.swift \
  -framework AppKit -framework SwiftUI -framework Security \
  -o "$TMP/$EXEC_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$SRC/MarkTemplate.png" "$APP/Contents/Resources/MarkTemplate.png"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 2. Icon. Shuttle.icon is an Icon Composer bundle, which iconutil cannot read —
#    it needs actool. Note it must be passed DIRECTLY: wrapping it in an
#    Assets.xcassets makes actool silently produce nothing at all. Compiling it this
#    way yields both Assets.car (the Liquid Glass artwork macOS 26 uses via
#    CFBundleIconName) and a legacy Shuttle.icns fallback.
ICON_KEYS=""
DEVDIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ -d "$SRC/Shuttle.icon" && -x /usr/bin/actool && -d "$DEVDIR" ]]; then
  echo "==> Compiling icon (actool)"
  if DEVELOPER_DIR="$DEVDIR" /usr/bin/actool "$SRC/Shuttle.icon" \
       --compile "$APP/Contents/Resources" \
       --platform macosx --minimum-deployment-target 14.0 \
       --app-icon Shuttle \
       --output-partial-info-plist "$TMP/icon.plist" >/dev/null 2>&1 \
     && [[ -f "$APP/Contents/Resources/Shuttle.icns" ]]; then
    ICON_KEYS="  <key>CFBundleIconFile</key><string>Shuttle</string>
  <key>CFBundleIconName</key><string>Shuttle</string>"
    echo "    Assets.car + Shuttle.icns"
  else
    echo "    actool produced nothing; continuing without a custom icon"
  fi
else
  echo "==> No icon step (needs Xcode.app for actool); continuing"
fi

# The relay is plain HTTP on a private address, so ATS has to permit it -- without
# permission the load fails with -1022 before any socket is opened, which surfaces
# as "can't reach the relay" with nothing in lsof and nothing in the relay log.
#
# NSAllowsArbitraryLoads is set UNCONDITIONALLY, and that is a deliberate decision
# for a distributable build rather than laziness. ATS exceptions are keyed on a
# HOST baked into Info.plist at build time, so without this a downloaded release
# could only ever talk to whatever address the person who built it happened to
# use -- typing your own NAS into Settings would fail, and probing for one could
# not work at all. Both are core to setup, so the alternative is not "a more
# secure app", it is "an app nobody else can configure".
#
# What it costs is bounded: this app speaks to exactly one server, one the user
# names themselves, on their own private network -- usually over WireGuard, which
# is already encrypted underneath. ATS protects against passive interception of
# public-internet HTTP, which is not the situation here.
#
# The per-host exception below is still emitted when a host is baked in, so that
# configuration stays explicit and documented in the bundle.
RELAY_KEYS="  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>"
if [[ -n "$RELAY_HOST" ]]; then
  RELAY_KEYS="  <key>SHRelayBase</key><string>http://${RELAY_HOST}:8789</string>
${RELAY_KEYS}
    <key>NSExceptionDomains</key>
    <dict>
      <key>${RELAY_HOST}</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
        <key>NSIncludesSubdomains</key><false/>
      </dict>
    </dict>"
  echo "==> Baking in default relay host ${RELAY_HOST}"
else
  echo "==> No SHUTTLE_RELAY_HOST set; the app opens with an empty address and"
  echo "    finds or accepts one in Setup."
fi
RELAY_KEYS="${RELAY_KEYS}
  </dict>"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shuttle</string>
  <key>CFBundleDisplayName</key><string>Shuttle</string>
  <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
${ICON_KEYS}
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
${RELAY_KEYS}
</dict>
</plist>
PLIST

# 3. Sign with a STABLE self-signed identity, creating it on first use.
#
#    This is not cosmetic. An ad-hoc signature's designated requirement is
#    cdhash-based:
#        designated => cdhash H"5dc6c2e7..."
#    i.e. bound to the binary's hash, so EVERY rebuild is a different code identity.
#    The Keychain ACL keys on exactly that, so every rebuild made macOS treat the app
#    as a stranger and put up a "Shuttle wants to use your confidential information"
#    dialog that BLOCKS the app until it is answered -- and the token read behind it
#    cost ~6s of ACL evaluation even once allowed.
#
#    A self-signed certificate binds it to the cert instead:
#        designated => identifier "com.britsch.shuttle" and certificate leaf = H"4adea847..."
#    which is stable across every future build. One prompt, ever.
#
#    codesign does NOT require the certificate to be TRUSTED in order to sign with it,
#    so no admin rights and no trust-settings prompt are needed -- `security
#    find-identity -p codesigning` will still report "0 valid identities", which is
#    expected and harmless here.
SIGN_ID="${SHUTTLE_SIGN_IDENTITY:-Shuttle Local Signing}"

if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "==> Creating a stable signing identity: $SIGN_ID"
  CERTDIR="$(mktemp -d)"
  if openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -keyout "$CERTDIR/key.pem" -out "$CERTDIR/cert.pem" \
        -subj "/CN=$SIGN_ID" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 \
     && openssl pkcs12 -export -legacy -out "$CERTDIR/id.p12" \
        -inkey "$CERTDIR/key.pem" -in "$CERTDIR/cert.pem" \
        -passout pass:shuttle -name "$SIGN_ID" >/dev/null 2>&1 \
     && security import "$CERTDIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P shuttle -A >/dev/null 2>&1; then
    echo "    created"
  else
    echo "    could not create one; falling back to ad-hoc"
  fi
  # The private key lives in the Keychain now; do not leave a copy on disk.
  rm -rf "$CERTDIR"
fi

if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "==> Signing as \"$SIGN_ID\""
  codesign --force --sign "$SIGN_ID" "$APP" 2>&1 | sed 's/^/    /' || true
else
  echo "==> Signing (ad-hoc — expect a Keychain prompt after every rebuild)"
  codesign --force --sign - "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo "==> Built: $APP"

# 4. Install, replacing whatever is there. The old bundle is only removed once the
#    new one exists.
if [[ "$RELEASE" == "1" ]]; then
  ZIP="$DIST/Shuttle-v${VERSION}.zip"
  rm -f "$ZIP"
  # ditto, not `zip`: it preserves the bundle's symlinks, resource forks and --
  # the load-bearing part -- the code signature. A zip built any other way can
  # arrive with a broken signature that Gatekeeper refuses outright.
  # --keepParent so the archive expands to Shuttle.app rather than its contents.
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  echo "==> Release zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
  echo "    Attach it with:"
  echo "        gh release create v${VERSION} \"$ZIP\" --title \"Shuttle v${VERSION}\" --notes-file <notes>"
fi

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to $INSTALLED"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  # Nudge Launch Services so the Dock/Spotlight pick up the replacement.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALLED" >/dev/null 2>&1 || true
  echo "==> Installed"
fi
