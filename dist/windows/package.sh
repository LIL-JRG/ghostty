#!/usr/bin/env bash
# Package Ghostty for Windows: builds a release and produces a portable
# ZIP under zig-out/dist/. Run from the repository root in Git Bash:
#
#   ./dist/windows/package.sh [version]
#
# Requires: zig in PATH (or ZIG env var), PowerShell (for Compress-Archive).
set -euo pipefail

VERSION="${1:-1.3.2}"
ZIG="${ZIG:-zig}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE_NAME="ghostty-${VERSION}-windows-x86_64"
STAGE="$ROOT/zig-out/dist/$STAGE_NAME"

echo "==> Building release..."
(cd "$ROOT" && "$ZIG" build -Dapp-runtime=win32 -Dtarget=native-native-gnu \
    --release=fast -Dversion-string="$VERSION")

echo "==> Staging $STAGE_NAME..."
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/share"
cp "$ROOT/zig-out/bin/ghostty.exe" "$STAGE/bin/"
# share/ghostty holds the resources; share/terminfo is the sentinel the
# resources-dir detection looks for relative to the executable.
cp -r "$ROOT/zig-out/share/ghostty" "$STAGE/share/"
cp -r "$ROOT/zig-out/share/terminfo" "$STAGE/share/"
cp "$ROOT/LICENSE" "$STAGE/"
cp "$ROOT/WINDOWS.md" "$STAGE/README-WINDOWS.md"

echo "==> Zipping..."
rm -f "$ROOT/zig-out/dist/$STAGE_NAME.zip"
powershell.exe -NoProfile -Command \
    "Compress-Archive -Path '$(cygpath -w "$STAGE")' -DestinationPath '$(cygpath -w "$ROOT/zig-out/dist/$STAGE_NAME.zip")'"

echo "==> Done:"
ls -la "$ROOT/zig-out/dist/$STAGE_NAME.zip"
