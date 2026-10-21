#!/bin/zsh
set -euo pipefail

if (( $# )); then
    print -u2 "Usage: Uninstall LDAC Output.command"
    exit 2
fi
/usr/bin/sudo /bin/sh <<'REMOVE'
set -eu
ldac_driver=/Library/Audio/Plug-Ins/HAL/AcoupletLDACOutput.driver
ldac_legacy_driver=/Library/Audio/Plug-Ins/HAL/XM5LDACOutput.driver
if /usr/bin/pgrep -f '^/Applications/(Acouplet\.app/Contents/MacOS/Acouplet|XM5 Control( Native)?\.app/Contents/MacOS/XM5 Control)( |$)' >/dev/null; then
    printf '%s\n' 'Stop LDAC and quit Acouplet or XM5 Control normally before removing the audio driver.' >&2
    exit 1
fi
if [ -e "$ldac_driver" ] || [ -L "$ldac_driver" ] || [ -e "$ldac_legacy_driver" ] || [ -L "$ldac_legacy_driver" ]; then
    ldac_app=/Applications/Acouplet.app
    ldac_app_identifier=dev.baglayan.Acouplet
    ldac_app_executable=Acouplet
    if [ ! -e "$ldac_app" ] && [ ! -L "$ldac_app" ] && [ ! -e "$ldac_driver" ] && [ ! -L "$ldac_driver" ]; then
        ldac_app='/Applications/XM5 Control Native.app'
        ldac_app_identifier=local.xm5control.native
        ldac_app_executable='XM5 Control'
    fi
    if [ -L "$ldac_app" ] || [ ! -d "$ldac_app" ] || [ -L "$ldac_app/Contents" ] ||
       [ -L "$ldac_app/Contents/Info.plist" ] || [ -L "$ldac_app/Contents/MacOS" ] ||
       [ -L "$ldac_app/Contents/MacOS/$ldac_app_executable" ] ||
       [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ldac_app/Contents/Info.plist" 2>/dev/null || true)" != "$ldac_app_identifier" ] ||
       [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ldac_app/Contents/Info.plist" 2>/dev/null || true)" != "$ldac_app_executable" ]; then
        printf '%s\n' 'A valid installed Acouplet or XM5 Control app is required to verify driver ownership. Nothing was removed.' >&2
        exit 1
    fi
    ldac_certificate="$(/usr/libexec/PlistBuddy -c 'Print :AcoupletSigningCertificateSHA1' "$ldac_app/Contents/Info.plist" 2>/dev/null || true)"
    if [ -n "$ldac_certificate" ]; then
        if [ "${#ldac_certificate}" != 40 ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :AcoupletDistribution' "$ldac_app/Contents/Info.plist")" != development ]; then
            printf '%s\n' 'The installed app has an invalid private signing identity. Nothing was removed.' >&2
            exit 1
        fi
        case "$ldac_certificate" in
            *[!A-Fa-f0-9]*) printf '%s\n' 'The installed app has an invalid private signing identity. Nothing was removed.' >&2; exit 1 ;;
        esac
        ldac_requirement="certificate leaf = H\"$ldac_certificate\""
        /usr/bin/codesign --verify --deep --strict --all-architectures \
            --test-requirement="=identifier \"$ldac_app_identifier\" and $ldac_requirement" "$ldac_app"
    else
        /usr/bin/codesign --verify --deep --strict --all-architectures --test-requirement='=anchor apple generic' "$ldac_app"
        ldac_team="$(/usr/bin/codesign --display --verbose=2 "$ldac_app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
        if [ "${#ldac_team}" != 10 ]; then
            printf '%s\n' 'The installed app has no valid signing team. Nothing was removed.' >&2
            exit 1
        fi
        case "$ldac_team" in
            *[!A-Z0-9]*) printf '%s\n' 'The installed app has no valid signing team. Nothing was removed.' >&2; exit 1 ;;
        esac
        ldac_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$ldac_team\""
    fi
    for ldac_path in "$ldac_driver" "$ldac_legacy_driver"; do
        case "$ldac_path" in
            */AcoupletLDACOutput.driver) ldac_identifier=dev.baglayan.Acouplet.LDACOutput; ldac_executable=AcoupletVirtualOutput ;;
            */XM5LDACOutput.driver) ldac_identifier=local.xm5control.ldac-output-driver; ldac_executable=XM5VirtualOutput ;;
        esac
        if [ -e "$ldac_path" ] || [ -L "$ldac_path" ]; then
            if [ -L "$ldac_path" ] || [ ! -d "$ldac_path" ] || [ -L "$ldac_path/Contents" ] ||
               [ -L "$ldac_path/Contents/Info.plist" ] || [ -L "$ldac_path/Contents/MacOS" ] ||
               [ -L "$ldac_path/Contents/MacOS/$ldac_executable" ] ||
               [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ldac_path/Contents/Info.plist" 2>/dev/null || true)" != "$ldac_identifier" ] ||
               [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ldac_path/Contents/Info.plist" 2>/dev/null || true)" != "$ldac_executable" ]; then
                printf '%s\n' 'A driver path does not match the owned LDAC output identity. Nothing was removed.' >&2
                exit 1
            fi
            /usr/bin/codesign --verify --deep --strict --all-architectures \
                --test-requirement="=identifier \"$ldac_identifier\" and $ldac_requirement" "$ldac_path"
        fi
    done
    for ldac_path in "$ldac_legacy_driver" "$ldac_driver"; do
        if [ -d "$ldac_path" ]; then
            /bin/rm -rf "$ldac_path"
        fi
    done
fi
for ldac_identifier in dev.baglayan.Acouplet.LDACOutput local.xm5control.ldac-output-driver; do
    if /usr/sbin/pkgutil --pkg-info "$ldac_identifier" >/dev/null 2>&1; then
        /usr/sbin/pkgutil --forget "$ldac_identifier" >/dev/null
    fi
done
printf '%s\n' 'Only the owned Acouplet and XM5 LDAC output drivers and installer receipts were removed.'
printf '%s\n' 'Restart your Mac to finish unloading them. Core Audio was not restarted.'
REMOVE
