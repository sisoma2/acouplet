#!/bin/sh
set -eu

hud_source="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ "${4:-}" != --uncached ]; then
    DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
    export DEVELOPER_DIR
    exec /usr/bin/python3 "$hud_source/../../Packaging/build_cache.py" --cache "$2/Cache" \
        --input "$hud_source" --output "$1" --output "$3" -- /bin/sh "$0" "$@" --uncached
fi
hud_output="$1"
hud_build="$2"
hud_check="$3"
hud_sdk="${SDKROOT:-$(/usr/bin/xcrun --sdk macosx --show-sdk-path)}"
hud_swift="$(/usr/bin/xcrun --find swiftc)"
hud_clang="$(/usr/bin/xcrun --find clang)"
hud_language="${SWIFT_VERSION:-6}"
hud_language="${hud_language%%.*}"
hud_optimization="${SWIFT_OPTIMIZATION_LEVEL:--Onone}"
if [ "${CONFIGURATION:-Debug}" = Release ]; then hud_optimization="${SWIFT_OPTIMIZATION_LEVEL:--O}"; fi
hud_debug=""
if [ "${CONFIGURATION:-Debug}" = Debug ]; then hud_debug="-DDEBUG"; fi
mkdir -p "$hud_build/overlay" "$(dirname -- "$hud_output")" "$(dirname -- "$hud_check")"
"$hud_swift" -target arm64-apple-macos27.2 -sdk "$hud_sdk" -emit-module -enable-library-evolution -module-name SystemBannerUI "$hud_source/SystemBannerUI.swift" -emit-module-path "$hud_build/overlay/SystemBannerUI.swiftmodule"
"$hud_clang" -target arm64-apple-macos27.2 -isysroot "$hud_sdk" -c "$hud_source/NativeHUDABI.c" -o "$hud_build/NativeHUDABI.o" -Wall -Wextra -Werror
set -- -target arm64-apple-macos27.2 -sdk "$hud_sdk" -swift-version "$hud_language" -strict-concurrency=complete "$hud_optimization" $hud_debug -module-name SonyNativeHUD -I "$hud_build/overlay" -F "$hud_sdk/System/Library/PrivateFrameworks" -framework SystemBannerUI -Xlinker -U -Xlinker '_$s14SystemBannerUI0aB7ContentP18wantsDismissButtonSbvgTq' -Xlinker -U -Xlinker '_$s14SystemBannerUI0aB7ContentP23accessibilityIdentifierSSSgvgTq' -import-objc-header "$hud_source/NativeHUDABI.h" "$hud_build/NativeHUDABI.o" "$hud_source/BannerLifetime.swift" "$hud_source/SonyNativeHUD.swift"
"$hud_swift" "$@" -emit-library -Xlinker -install_name -Xlinker '@rpath/SonyNativeHUD.dylib' -o "$hud_output"
"$hud_swift" "$@" "$hud_source/NativeHUDCheck.swift" -o "$hud_check"
if [ "${CODE_SIGNING_ALLOWED:-NO}" != NO ]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime --timestamp=none "$hud_output" "$hud_check"
fi
