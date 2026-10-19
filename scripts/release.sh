#!/usr/bin/env bash
# Builds, signs, notarizes and staples build/Swapjutsu-<version>.dmg and zips its dSYMs. macOS only.
# Run with --help for usage and prerequisites.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/release.sh [--skip-notarize] [--skip-smoke]

Archives a Release build of Swapjutsu.app (arm64, hardened runtime, App Sandbox, with
the unsandboxed swapjutsu binary in Contents/Helpers), exports it signed with your
Developer ID, notarizes and staples the app, packs it with an Applications link into
build/Swapjutsu-<version>.dmg, signs, notarizes and staples the DMG, checks both
with Gatekeeper, launches the app from the DMG once
(scripts/smoke-launch.sh) and writes build/Swapjutsu-<version>.dmg.sha256.
The dSYMs go to build/Swapjutsu-<version>-dSYMs.zip.

The version and build number are MARKETING_VERSION and CURRENT_PROJECT_VERSION in
project.yml. The build number must be higher than in the previous v*.*.* tag.

  --skip-notarize   Local test build: no notarization and no Gatekeeper check, and a
                    build number that is not higher only warns. Signed ad-hoc, or with
                    your Developer ID when DEVELOPMENT_TEAM is set. The DMG will not
                    pass Gatekeeper on other Macs.
  --skip-smoke      Don't launch the app from the DMG. Only for a Mac without a
                    logged-in GUI session; a release should always be launched once.
  -h, --help        Show this help.

Environment (not needed with --skip-notarize):
  DEVELOPMENT_TEAM  Apple Developer Team ID (10 characters).
  NOTARY_PROFILE    Keychain profile created once with
                    `xcrun notarytool store-credentials <name> --apple-id … --team-id …`.
  NOTARY_KEY        Instead of NOTARY_PROFILE, e.g. on CI: path to an App Store Connect
                    API key (AuthKey_XXXXXXXXXX.p8), with NOTARY_KEY_ID and NOTARY_ISSUER.
  SIGNING_IDENTITY  Optional. Defaults to the "Developer ID Application: … (DEVELOPMENT_TEAM)"
                    certificate in your keychain.

Requires macOS on Apple Silicon with Xcode 27+ and XcodeGen (brew install xcodegen).
A signed release also needs the Developer ID Application certificate and its private
key in your login keychain.
EOF
}

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "› $*"; }

NOTARIZE=1
SMOKE=1
while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --skip-notarize) NOTARIZE=0 ;;
        --skip-smoke) SMOKE=0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

cd "$(dirname "${BASH_SOURCE[0]}")/.."

[[ $(uname -s) == Darwin ]] || die "release builds need macOS (xcodebuild, codesign, hdiutil, notarytool)."
for tool in git xcodegen xcodebuild xcrun codesign hdiutil ditto lipo shasum plutil security; do
    command -v "$tool" >/dev/null || die "'$tool' not found.$([[ $tool == xcodegen ]] && echo " Install it with: brew install xcodegen")"
done

setting() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\\1/p" | head -n 1; }
VERSION=$(setting MARKETING_VERSION <project.yml)
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION in project.yml must look like 1.2.3, got '$VERSION'."
BUILD_NUMBER=$(setting CURRENT_PROJECT_VERSION <project.yml)
APP_ID_PREFIX=$(setting APP_ID_PREFIX <project.yml)
[[ -n $APP_ID_PREFIX ]] || die "no APP_ID_PREFIX in project.yml."
[[ $BUILD_NUMBER =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION in project.yml must be a whole number, got '$BUILD_NUMBER'."
# The previous release is the newest version tag reachable from HEAD, other than the one being built.
PREVIOUS_TAG=$(git describe --tags --abbrev=0 --match 'v*.*.*' --exclude "v$VERSION" HEAD 2>/dev/null || true)
if [[ -n $PREVIOUS_TAG ]]; then
    PREVIOUS_BUILD=$(git show "$PREVIOUS_TAG:project.yml" | setting CURRENT_PROJECT_VERSION)
    if [[ $PREVIOUS_BUILD =~ ^[0-9]+$ ]] && ((10#$BUILD_NUMBER <= 10#$PREVIOUS_BUILD)); then
        message="build number $BUILD_NUMBER is not higher than $PREVIOUS_BUILD in $PREVIOUS_TAG; increment CURRENT_PROJECT_VERSION in project.yml."
        ((NOTARIZE)) && die "$message"
        echo "warning: $message" >&2
    fi
fi

if ((NOTARIZE)); then
    [[ -n ${DEVELOPMENT_TEAM:-} ]] || die "set DEVELOPMENT_TEAM to your Apple Team ID, or pass --skip-notarize for a local build."
    if [[ -n ${NOTARY_KEY:-} ]]; then
        [[ -f $NOTARY_KEY ]] || die "NOTARY_KEY '$NOTARY_KEY' is not a file."
        [[ -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER:-} ]] || die "NOTARY_KEY needs NOTARY_KEY_ID and NOTARY_ISSUER."
        NOTARY_AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    elif [[ -n ${NOTARY_PROFILE:-} ]]; then
        NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
    else
        die "set NOTARY_PROFILE (or NOTARY_KEY with NOTARY_KEY_ID and NOTARY_ISSUER), or pass --skip-notarize."
    fi
fi
if [[ -n ${DEVELOPMENT_TEAM:-} ]]; then
    [[ $DEVELOPMENT_TEAM =~ ^[A-Z0-9]{10}$ ]] || die "DEVELOPMENT_TEAM must be a 10-character Team ID, got '$DEVELOPMENT_TEAM'."
    if [[ -z ${SIGNING_IDENTITY:-} ]]; then
        SIGNING_IDENTITY=$(security find-identity -v -p codesigning |
            sed -nE "s/.*\"(Developer ID Application: .*\\($DEVELOPMENT_TEAM\\))\".*/\\1/p" | head -n 1)
        [[ -n $SIGNING_IDENTITY ]] ||
            die "no valid 'Developer ID Application' certificate for team $DEVELOPMENT_TEAM in your keychain."
    fi
elif [[ -n ${SIGNING_IDENTITY:-} ]]; then
    die "SIGNING_IDENTITY needs DEVELOPMENT_TEAM, the team the export signs for."
fi
if ((NOTARIZE)); then
    # Checked before the build, so wrong credentials fail in seconds rather than after it.
    xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 ||
        die "notarization credentials not usable (xcrun notarytool history failed)."
fi

BUILD=build
ARCHIVE=$BUILD/Swapjutsu.xcarchive
EXPORT=$BUILD/export
APP=$EXPORT/Swapjutsu.app
DMG=$BUILD/Swapjutsu-$VERSION.dmg
DSYMS=$BUILD/Swapjutsu-$VERSION-dSYMs.zip
DMG_ROOT=$BUILD/dmg-root

rm -rf "$ARCHIVE" "$EXPORT" "$DMG" "$DMG.sha256" "$DSYMS" "$DMG_ROOT"
mkdir -p "$BUILD"

step "xcodegen generate"
xcodegen generate --quiet

# Version, build number, arm64 and the hardened runtime come from project.yml; only the signature differs here.
if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    SIGN_SETTINGS=(
        CODE_SIGN_STYLE=Manual
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
        CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
    SIGNED_WITH="Developer ID ($SIGNING_IDENTITY)"
else
    SIGN_SETTINGS=(CODE_SIGN_IDENTITY=-)
    SIGNED_WITH="ad-hoc"
fi

step "xcodebuild archive ($VERSION ($BUILD_NUMBER), Release, arm64, $SIGNED_WITH)"
# The app's own scheme: the package also has an executable named Swapjutsu. ARCHS here as well as in project.yml:
# project.yml doesn't reach the package's targets, which a generic destination would also compile for x86_64.
# OTHER_CFLAGS for the same reason: MLX's C and C++ sources put __FILE__ into their error messages, and the prefix map
# shortens it to a path inside the checkout, so the binary doesn't carry the build Mac's home folder. Debug info
# keeps the full paths for the dSYMs.
xcodebuild archive \
    -project Swapjutsu.xcodeproj \
    -scheme Swapjutsu \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$BUILD/DerivedData" \
    -quiet \
    ARCHS=arm64 \
    OTHER_CFLAGS="\$(inherited) -fmacro-prefix-map=$PWD/=" \
    "${SIGN_SETTINGS[@]}"

if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    step "export (developer-id)"
    cat >"$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$SIGNING_IDENTITY</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT" \
        -exportOptionsPlist "$BUILD/ExportOptions.plist" \
        -quiet
else
    step "copy the app out of the archive (ad-hoc, no export)"
    mkdir -p "$EXPORT"
    ditto "$ARCHIVE/Products/Applications/Swapjutsu.app" "$APP"
fi
[[ -d $APP ]] || die "the export produced no '$APP'."

step "verify the app"
codesign --verify --deep --strict --verbose=2 "$APP"
BINARY=$APP/Contents/MacOS/Swapjutsu
ARCHS_BUILT=$(lipo -archs "$BINARY")
[[ $ARCHS_BUILT == arm64 ]] || die "expected an arm64-only app, got: $ARCHS_BUILT."
# Captured first: `grep -q` stops reading at the first match, and pipefail would turn codesign's SIGPIPE into a failure.
SIGNATURE=$(codesign --display --verbose=2 "$APP" 2>&1)
[[ $SIGNATURE == *flags=*runtime* ]] || die "the app is not signed with the hardened runtime."
if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    [[ $SIGNATURE == *"Authority=$SIGNING_IDENTITY"* ]] || die "the app is not signed by $SIGNING_IDENTITY."
    [[ $SIGNATURE == *Timestamp=* ]] || die "the app's signature has no secure timestamp."
fi

# Exactly the entitlements project.yml declares (all true but the app group), and never get-task-allow:
# notarization rejects it.
ENTITLEMENTS=$BUILD/Swapjutsu.signed-entitlements.plist
codesign --display --entitlements - --xml "$APP" 2>/dev/null >"$ENTITLEMENTS"
plist_keys() { /usr/libexec/PlistBuddy -c Print "$1" | sed -nE 's/^    ([^ ]+) = .*/\1/p' | sort; }
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
if plist_value "$ENTITLEMENTS" com.apple.security.get-task-allow >/dev/null; then
    die "the app is signed with com.apple.security.get-task-allow; notarization would reject it."
fi
EXPECTED_KEYS=$(plist_keys "$BUILD/Swapjutsu.entitlements")
SIGNED_KEYS=$(plist_keys "$ENTITLEMENTS")
[[ -n $EXPECTED_KEYS ]] || die "no entitlements in $BUILD/Swapjutsu.entitlements (generated from project.yml)."
[[ $SIGNED_KEYS == "$EXPECTED_KEYS" ]] ||
    die "the app's entitlements differ from project.yml:$(diff <(echo "$EXPECTED_KEYS") <(echo "$SIGNED_KEYS") | sed 's/^/ /' || true)"
GROUP_KEY=com.apple.security.application-groups
for key in $EXPECTED_KEYS; do
    [[ $key == "$GROUP_KEY" ]] && continue
    [[ $(plist_value "$ENTITLEMENTS" "$key") == true ]] || die "entitlement $key is not true."
done
[[ $(plist_value "$ENTITLEMENTS" com.apple.security.app-sandbox) == true ]] || die "the app is not sandboxed."
# The agent socket's group: the signing team's, and the one Info.plist tells the app and the swapjutsu binary.
APP_GROUP=$(plist_value "$ENTITLEMENTS" "$GROUP_KEY:0")
EXPECTED_GROUP=${DEVELOPMENT_TEAM:-}.$APP_ID_PREFIX.swapjutsu
[[ $APP_GROUP == "$EXPECTED_GROUP" && -z $(plist_value "$ENTITLEMENTS" "$GROUP_KEY:1") ]] ||
    die "the app group entitlement is '$APP_GROUP', expected only '$EXPECTED_GROUP'."
[[ $(plutil -extract SwapjutsuAppGroup raw -o - "$APP/Contents/Info.plist") == "$APP_GROUP" ]] ||
    die "SwapjutsuAppGroup in Info.plist is not the app group $APP_GROUP."

BUNDLE_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
[[ $BUNDLE_VERSION == "$VERSION" ]] || die "the app reports version $BUNDLE_VERSION, expected $VERSION."
BUNDLE_BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
[[ $BUNDLE_BUILD == "$BUILD_NUMBER" ]] || die "the app reports build $BUNDLE_BUILD, expected $BUILD_NUMBER."
echo "$ARCHS_BUILT, hardened runtime, $SIGNED_WITH, version $BUNDLE_VERSION ($BUNDLE_BUILD)"
echo "entitlements: $(echo "$SIGNED_KEYS" | tr '\n' ' ')(no get-task-allow), app group $APP_GROUP"

step "verify the swapjutsu binary"
# What agents run (`swapjutsu mcp`): signed like the app, by the same team, and never sandboxed, or it couldn't start
# the app or open the socket in the group container.
HELPER=$APP/Contents/Helpers/swapjutsu
[[ -x $HELPER ]] || die "the app has no executable $HELPER."
codesign --verify --strict --verbose=2 "$HELPER"
[[ $(lipo -archs "$HELPER") == arm64 ]] || die "expected an arm64-only swapjutsu, got: $(lipo -archs "$HELPER")."
HELPER_SIGNATURE=$(codesign --display --verbose=2 "$HELPER" 2>&1)
[[ $HELPER_SIGNATURE == *flags=*runtime* ]] || die "swapjutsu is not signed with the hardened runtime."
team_id() { sed -nE 's/^TeamIdentifier=(.*)/\1/p' <<<"$1"; }
[[ $(team_id "$HELPER_SIGNATURE") == "$(team_id "$SIGNATURE")" ]] ||
    die "swapjutsu is signed for team '$(team_id "$HELPER_SIGNATURE")', the app for '$(team_id "$SIGNATURE")'."
if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    [[ $HELPER_SIGNATURE == *"Authority=$SIGNING_IDENTITY"* ]] || die "swapjutsu is not signed by $SIGNING_IDENTITY."
    [[ $HELPER_SIGNATURE == *Timestamp=* ]] || die "swapjutsu's signature has no secure timestamp."
fi
HELPER_ENTITLEMENTS=$BUILD/swapjutsu.signed-entitlements.plist
codesign --display --entitlements - --xml "$HELPER" 2>/dev/null >"$HELPER_ENTITLEMENTS"
if [[ -s $HELPER_ENTITLEMENTS ]]; then
    for key in com.apple.security.app-sandbox com.apple.security.get-task-allow; do
        if plist_value "$HELPER_ENTITLEMENTS" "$key" >/dev/null; then die "swapjutsu is signed with $key."; fi
    done
fi
# Run once: it finds the app it is bundled in through ../../Info.plist.
HELPER_VERSION=$("$HELPER" --version)
[[ $HELPER_VERSION == "$VERSION" ]] || die "swapjutsu --version is '$HELPER_VERSION', expected $VERSION."
echo "arm64, hardened runtime, team $(team_id "$HELPER_SIGNATURE"), not sandboxed, version $HELPER_VERSION"

step "zip dSYMs into $DSYMS"
APP_DSYM=$ARCHIVE/dSYMs/Swapjutsu.app.dSYM
[[ -d $APP_DSYM ]] || die "the archive has no '$APP_DSYM'; crash reports could not be symbolicated."
# Crash reports match a dSYM by UUID.
uuids() { xcrun dwarfdump --uuid "$1" | awk '{ print $2 }' | sort; }
[[ $(uuids "$BINARY") == "$(uuids "$APP_DSYM")" ]] || die "the dSYM in the archive does not match the exported app."
ditto -c -k --keepParent "$ARCHIVE/dSYMs" "$DSYMS"

# Usage: notarize FILE. Waits for the result and prints Apple's log if it is not accepted.
notarize() {
    local result status submission
    result=$(xcrun notarytool submit "$1" --wait --output-format json "${NOTARY_AUTH[@]}")
    status=$(plutil -extract status raw -o - - <<<"$result")
    submission=$(plutil -extract id raw -o - - <<<"$result")
    if [[ $status != Accepted ]]; then
        xcrun notarytool log "$submission" "${NOTARY_AUTH[@]}" >&2 || true
        die "notarization of ${1##*/} finished with status '$status' (submission $submission); the log is above."
    fi
    echo "accepted (submission $submission)"
}

if ((NOTARIZE)); then
    # Stapled before it goes into the DMG, so the copy in /Applications passes Gatekeeper offline too.
    step "notarize and staple the app (this usually takes a few minutes)"
    APP_ZIP=$BUILD/notarize-app.zip
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
    notarize "$APP_ZIP"
    rm -f "$APP_ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

step "create $DMG"
# hdiutil from a folder with the app and an Applications link: no Finder scripting, so it also runs headless.
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Swapjutsu.app"
ln -s /Applications "$DMG_ROOT/Applications"
# ULFO (LZFSE) is smaller than UDZO and opens on every macOS the app supports.
hdiutil create -quiet -volname Swapjutsu -srcfolder "$DMG_ROOT" -fs APFS -format ULFO -ov "$DMG"
rm -rf "$DMG_ROOT"

if [[ -n ${SIGNING_IDENTITY:-} ]]; then
    step "sign the DMG"
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

if ((NOTARIZE)); then
    step "notarize the DMG (this usually takes a few minutes)"
    notarize "$DMG"

    step "staple and check Gatekeeper"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl -a -vv -t open --context context:primary-signature "$DMG"
    spctl -a -vv "$APP"
else
    step "skipped notarization and the Gatekeeper check (--skip-notarize)"
fi

if ((SMOKE)); then
    step "launch the app from the DMG (smoke test)"
    scripts/smoke-launch.sh "$DMG"
else
    step "skipped launching the app (--skip-smoke)"
fi

step "done"
(cd "$BUILD" && shasum -a 256 "${DMG##*/}" | tee "${DMG##*/}.sha256")
echo "dSYMs: $DSYMS"
