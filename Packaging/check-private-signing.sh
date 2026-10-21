#!/bin/sh
set -eu

certificate="${ACOUPLET_SIGNING_CERTIFICATE_SHA1:-}"
if [ "${#certificate}" != 40 ] || [ -z "${CODE_SIGN_IDENTITY:-}" ] || [ "$CODE_SIGN_IDENTITY" = - ]; then
    printf '%s\n' 'Set CODE_SIGN_IDENTITY and ACOUPLET_SIGNING_CERTIFICATE_SHA1 to a private signing identity.' >&2
    exit 2
fi
case "$certificate" in
    *[!A-Fa-f0-9]*) printf '%s\n' 'The certificate fingerprint is invalid.' >&2; exit 2 ;;
esac
repo="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/acouplet-private-signing-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat > "$work/check.c" <<'SOURCE'
#include "AcoupletVirtualOutput.c"
int main(void) {
    return AcoupletClientAuthorized(getpid()) ? 0 : 1;
}
SOURCE
compile_check() {
    /usr/bin/xcrun --sdk macosx clang -std=gnu11 -fblocks -O2 -Werror \
        -I "$repo/Helpers/LDAC/VirtualOutput" "-DACOUPLET_SIGNING_CERTIFICATE_SHA1=\"$1\"" \
        -framework CoreAudio -framework CoreFoundation -framework Security "$work/check.c" -o "$work/check"
}
compile_check "$certificate"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --identifier dev.baglayan.Acouplet --timestamp=none "$work/check"
"$work/check"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --identifier dev.baglayan.Unrelated --timestamp=none "$work/check"
if "$work/check"; then
    printf '%s\n' 'The driver accepted an unrelated application identifier.' >&2
    exit 1
fi
/usr/bin/codesign --force --sign - --identifier dev.baglayan.Acouplet "$work/check"
if "$work/check"; then
    printf '%s\n' 'The driver accepted an ad-hoc signed application.' >&2
    exit 1
fi
other=0000000000000000000000000000000000000000
if [ "$certificate" = "$other" ]; then other=1111111111111111111111111111111111111111; fi
compile_check "$other"
/usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --identifier dev.baglayan.Acouplet --timestamp=none "$work/check"
if "$work/check"; then
    printf '%s\n' 'The driver accepted a certificate outside its pinned identity.' >&2
    exit 1
fi
printf '%s\n' 'Private driver authentication accepted the pinned signer and rejected unrelated, ad-hoc and unpinned clients.'
