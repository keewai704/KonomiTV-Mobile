#!/usr/bin/env bash
#
# Build an unsigned .ipa for a real device from an already generated project.
#
# Usage: scripts/build-unsigned-ipa.sh <output.ipa> [marketing_version] [build_number]
#
# The .ipa is not signed: installing it requires re-signing with your own
# certificate (Xcode, AltStore, Sideloadly, ...).
set -euo pipefail

usage() {
    echo "usage: $0 <output.ipa> [marketing_version] [build_number]" >&2
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

output_path=$1
marketing_version=${2:-}
build_number=${3:-}

case "$output_path" in
    /*) ;;
    *) output_path="$PWD/$output_path" ;;
esac
mkdir -p "$(dirname "$output_path")"

derived_data_path="${DERIVED_DATA_PATH:-${RUNNER_TEMP:-/tmp}/DerivedData-ipa}"

build_settings=()
if [ -n "$marketing_version" ]; then
    build_settings+=("MARKETING_VERSION=$marketing_version")
fi
if [ -n "$build_number" ]; then
    build_settings+=("CURRENT_PROJECT_VERSION=$build_number")
fi

staging_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/konomitv-ipa.XXXXXX")
cleanup() {
    rm -rf "$staging_dir"
}
trap cleanup EXIT

echo "==> Building KonomiTV.app (Release, unsigned)"
xcodebuild build \
    -project KonomiTV.xcodeproj \
    -scheme KonomiTV \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data_path" \
    ${build_settings[@]+"${build_settings[@]}"} \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS=""

app_path="$derived_data_path/Build/Products/Release-iphoneos/KonomiTV.app"
if [ ! -d "$app_path" ]; then
    echo "error: app bundle not found at $app_path" >&2
    exit 1
fi

echo "==> Packaging $output_path"
mkdir -p "$staging_dir/Payload"
ditto "$app_path" "$staging_dir/Payload/KonomiTV.app"
# zip appends to an existing archive, so start from a clean file.
rm -f "$output_path"
(cd "$staging_dir" && zip -qry "$output_path" Payload)

echo "==> Verifying $output_path"
listing=$(unzip -l "$output_path")
for entry in 'Payload/KonomiTV.app/KonomiTV' 'Payload/KonomiTV.app/Info.plist'; do
    if ! printf '%s\n' "$listing" | grep -Fq "$entry"; then
        echo "error: $entry is missing from $output_path" >&2
        exit 1
    fi
done

binary_path="$app_path/KonomiTV"
archs=$(lipo -archs "$binary_path")
echo "architectures: $archs"
case " $archs " in
    *" arm64 "*) ;;
    *)
        echo "error: arm64 missing from $binary_path ($archs)" >&2
        exit 1
        ;;
esac

plist_path="$app_path/Info.plist"
short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_path")

ipa_bytes=$(wc -c < "$output_path" | tr -d '[:space:]')
ipa_size=$(du -h "$output_path" | cut -f1 | tr -d '[:space:]')

echo "ipa: $output_path"
echo "size: $ipa_size ($ipa_bytes bytes)"
echo "CFBundleShortVersionString: $short_version"
echo "CFBundleVersion: $bundle_version"
