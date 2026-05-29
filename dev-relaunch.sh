#!/bin/bash

set -e

APP_NAME="WindowLens"
LEGACY_APP_NAME="BetterTabbing"
INSTALL_APP="/Applications/WindowLens.app"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
DERIVED_APP="${DERIVED_APP:-}"

is_runnable_app() {
    local app_path="$1"
    local executable_name=""

    [ -d "$app_path" ] || return 1
    [ -d "$app_path/Contents/MacOS" ] || return 1

    if [ -f "$app_path/Contents/Info.plist" ]; then
        executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
    fi

    if [ -n "$executable_name" ] && [ -x "$app_path/Contents/MacOS/$executable_name" ]; then
        return 0
    fi

    find "$app_path/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit 2>/dev/null | grep -q .
}

find_derived_app_named() {
    local app_name="$1"
    local candidate=""

    while IFS= read -r candidate; do
        if is_runnable_app "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(
        find "$DERIVED_DATA_DIR" \
            -path "*/Index.noindex" -prune -o \
            -path "*/Build/Products/Debug/${app_name}.app" \
            -type d \
            -print 2>/dev/null
    )

    return 1
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Killing existing app..."
killall "$APP_NAME" 2>/dev/null || true
killall "$LEGACY_APP_NAME" 2>/dev/null || true

if [ -z "$DERIVED_APP" ]; then
    DERIVED_APP="$(find_derived_app_named "$APP_NAME" || true)"
fi

if [ -z "$DERIVED_APP" ]; then
    DERIVED_APP="$(find_derived_app_named "$LEGACY_APP_NAME" || true)"
fi

if [ -z "$DERIVED_APP" ] || ! is_runnable_app "$DERIVED_APP"; then
    echo "Could not find a runnable ${APP_NAME}.app or ${LEGACY_APP_NAME}.app in Xcode DerivedData."
    echo "Build the app in Xcode first, or set DERIVED_APP=/path/to/${APP_NAME}.app."
    exit 1
fi

echo "Using build: $DERIVED_APP"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Syncing build to /Applications..."
rsync -av --delete "$DERIVED_APP/" "$INSTALL_APP/"

if ! is_runnable_app "$INSTALL_APP"; then
    echo "Installed app is missing an executable: $INSTALL_APP"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Launching installed app..."
open "$INSTALL_APP"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done."
