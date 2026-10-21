#!/bin/zsh
set -euo pipefail

domain="gui/$(id -u)"
labels=(dev.baglayan.Acouplet.agent local.xm5control.native.agent local.xm5control.agent)
executables=("/Applications/Acouplet.app/Contents/MacOS/Acouplet" "/Applications/XM5 Control Native.app/Contents/MacOS/XM5 Control" "/Applications/XM5 Control.app/Contents/MacOS/XM5 Control")
identifiers=(dev.baglayan.Acouplet local.xm5control.native local.xm5control)
patterns=('^/Applications/Acouplet\.app/Contents/MacOS/Acouplet( |$)' '^/Applications/XM5 Control Native\.app/Contents/MacOS/XM5 Control( |$)' '^/Applications/XM5 Control\.app/Contents/MacOS/XM5 Control( |$)')
app_team=""
app_requirement=""

if (( EUID == 0 )); then
    print -u2 "Run this command as your normal logged-in user, without sudo."
    exit 1
fi
exec 9> /Applications/.Acouplet-install.lock
if ! /usr/bin/lockf -s -t 0 9; then
    print -u2 "Another Acouplet installation or service removal is running."
    exit 1
fi
exec 8> /Applications/.XM5-Control-install.lock
if ! /usr/bin/lockf -s -t 0 8; then
    print -u2 "A previous application installer or service removal is running."
    exit 1
fi
for index in {1..3}; do
    label="$labels[$index]"
    plist_path="$HOME/Library/LaunchAgents/$label.plist"
    installed_executable="$executables[$index]"
    installed_app="${installed_executable:h:h:h}"
    if [[ -e "$installed_app" || -L "$installed_app" ]]; then
        if [[ -L "$installed_app" || -L "$installed_app/Contents" || -L "$installed_app/Contents/Info.plist" ||
              -L "$installed_app/Contents/MacOS" || -L "$installed_executable" || ! -x "$installed_executable" || "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")" != "$identifiers[$index]" ]]; then
            print -u2 "An unexpected application exists at $installed_app; nothing was removed."
            exit 1
        fi
        /usr/bin/codesign --verify --deep --strict "$installed_app"
        if [[ -z "$app_requirement" ]]; then
            app_certificate="$(/usr/libexec/PlistBuddy -c 'Print :AcoupletSigningCertificateSHA1' "$installed_app/Contents/Info.plist" 2>/dev/null || true)"
            if [[ -n "$app_certificate" ]]; then
                if [[ ! "$app_certificate" =~ '^[A-Fa-f0-9]{40}$' || "$(/usr/libexec/PlistBuddy -c 'Print :AcoupletDistribution' "$installed_app/Contents/Info.plist")" != development ]]; then
                    print -u2 "The installed application's private signing identity is invalid; nothing was removed."
                    exit 1
                fi
                app_requirement="certificate leaf = H\"$app_certificate\""
            else
                app_team="$(/usr/bin/codesign --display --verbose=2 "$installed_app" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
                if [[ ! "$app_team" =~ '^[A-Z0-9]{10}$' ]]; then
                    print -u2 "The installed application is not Apple-signed; nothing was removed."
                    exit 1
                fi
                app_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$app_team\""
            fi
        fi
        /usr/bin/codesign --verify --deep --strict --test-requirement="=identifier \"$identifiers[$index]\" and $app_requirement" "$installed_app"
    fi
    if [[ -e "$plist_path" || -L "$plist_path" ]]; then
        if [[ -L "$plist_path" || "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist_path")" != "$label" ||
              "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_path")" != "$installed_executable" ]]; then
            print -u2 "The service configuration at $plist_path does not match Acouplet; nothing was removed."
            exit 1
        fi
    fi
    if service_state="$(/bin/launchctl print "$domain/$label" 2>/dev/null)"; then
        if [[ "$(print -r -- "$service_state" | awk '/^[[:space:]]*program = / { sub(/^[[:space:]]*program = /, ""); print; exit }')" != "$installed_executable" ]]; then
            print -u2 "The loaded service $label does not match Acouplet; nothing was removed."
            exit 1
        fi
    fi
done
for index in {1..3}; do
    original_pids="$(/usr/bin/pgrep -f "$patterns[$index]" || true)"
    if [[ -n "$original_pids" ]]; then
        if ! /usr/bin/osascript - "$identifiers[$index]" <<'APPLESCRIPT'
on run arguments
    with timeout of 30 seconds
        set appIdentifier to item 1 of arguments
        if application id appIdentifier is running then
            tell application id appIdentifier to quit
        end if
    end timeout
end run
APPLESCRIPT
        then
            print -u2 "The application did not finish quitting. Nothing was removed; finish its current operation and try again."
            exit 1
        fi
        for attempt in {1..120}; do
            original_running=false
            for original_pid in ${(f)original_pids}; do
                if /bin/kill -0 "$original_pid" 2>/dev/null; then
                    original_running=true
                    break
                fi
            done
            [[ "$original_running" == true ]] || break
            sleep 0.25
        done
        if [[ "$original_running" == true ]]; then
            print -u2 "The application has not finished quitting. Nothing was removed; try again after its current operation ends."
            exit 1
        fi
    fi
done
for label in "$labels[@]"; do
    if /bin/launchctl print "$domain/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "$domain/$label"
    fi
done
for pattern in "$patterns[@]"; do
    for attempt in {1..20}; do
        if ! /usr/bin/pgrep -f "$pattern" >/dev/null; then break; fi
        sleep 0.25
    done
    if /usr/bin/pgrep -f "$pattern" >/dev/null; then
        print -u2 "The application has not stopped. Its service configuration was kept; try again after it closes."
        exit 1
    fi
done
for installed_executable in "$executables[@]"; do
    if [[ -x "$installed_executable" ]]; then
        if ! "$installed_executable" --unregister-login-item; then
            print -u2 "The service was stopped, but its login item could not be unregistered. Run this command again to retry."
            exit 1
        fi
    fi
done
for label in "$labels[@]"; do
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
print "Acouplet's matching background services were stopped and removed."
print "The application and your preferences have been kept."
