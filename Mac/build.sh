#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build/module-cache build/Universal build/Apple-Silicon
stage="$(mktemp -d "${TMPDIR:-/tmp}/buddihex-build.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

for architecture in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "${architecture}-apple-macosx13.0" \
        -module-cache-path "$PWD/build/module-cache" -parse-as-library \
        Core.swift DXCC.swift Transport.swift BridgeTransport.swift Rotctld.swift Model.swift Views.swift App.swift \
        -framework SwiftUI -framework AppKit -framework Security \
        -o "$stage/BuddiHexRotator-$architecture"
done

for variant in arm64 Universal; do
    bundle="$stage/$variant/BuddiHex Rotator.app"
    executable="$bundle/Contents/MacOS/BuddiHexRotator"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    cp -X Info.plist "$bundle/Contents/"
    if [[ -f AppIcon.icns ]]; then cp -X AppIcon.icns "$bundle/Contents/Resources/"; fi
    if [[ "$variant" == Universal ]]; then
        lipo -create "$stage/BuddiHexRotator-arm64" "$stage/BuddiHexRotator-x86_64" -output "$executable"
        destination="build/Universal"
    else
        cp -X "$stage/BuddiHexRotator-arm64" "$executable"
        destination="build/Apple-Silicon"
    fi
    codesign --force --sign - "$bundle"
    codesign --verify --deep --strict "$bundle"
    ditto --norsrc "$bundle" "$destination/BuddiHex Rotator.app"
    printf 'Built: %s/%s/BuddiHex Rotator.app\n' "$PWD" "$destination"
done
