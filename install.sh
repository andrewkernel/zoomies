#!/bin/sh
# Zoomies installer: builds from source on your Mac, so macOS never shows an
# "unidentified developer" warning, and installs:
#   - the `zoomies` command to ~/.local/bin (no sudo)
#   - Zoomies.app to ~/Applications
#
#   curl -fsSL https://raw.githubusercontent.com/andrewkernel/zoomies/main/install.sh | sh
#
# Options (environment variables):
#   ZOOMIES_REF=v0.2.0      tag or branch to build (default: main)
#   ZOOMIES_BIN=~/bin       where to put the command
#   ZOOMIES_APPS=~/Apps     where to put Zoomies.app (default: ~/Applications)
#   ZOOMIES_NO_APP=1        skip the Mac app
set -eu

REPO="https://github.com/andrewkernel/zoomies"
REF="${ZOOMIES_REF:-main}"
BIN="${ZOOMIES_BIN:-$HOME/.local/bin}"
APPS="${ZOOMIES_APPS:-$HOME/Applications}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Zoomies currently supports macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || fail "macOS 14 (Sonoma) or newer is required; this Mac has $(sw_vers -productVersion)."
command -v swift >/dev/null 2>&1 || fail "Swift is missing. Install Apple's free Command Line Tools first:  xcode-select --install"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say "Downloading Zoomies ($REF)"
curl -fsSL "$REPO/archive/$REF.tar.gz" | tar -xz -C "$TMP" --strip-components 1

cd "$TMP"
say "Building (about a minute)"
swift build -c release --product zoomies >/dev/null
mkdir -p "$BIN"
cp .build/release/zoomies "$BIN/zoomies"
say "Installed $BIN/zoomies"

if [ -z "${ZOOMIES_NO_APP:-}" ]; then
  ./scripts/build-app.sh >/dev/null
  mkdir -p "$APPS"
  rm -rf "$APPS/Zoomies.app"
  cp -R .build/Zoomies.app "$APPS/Zoomies.app"
  say "Installed $APPS/Zoomies.app"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say "Add $BIN to your PATH:  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc" ;;
esac
if ! command -v llama-bench >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/llama-bench ]; then
  say "Zoomies tunes llama.cpp, which isn't installed yet:  brew install llama.cpp"
fi
say "Done. Try:  zoomies models$( [ -z "${ZOOMIES_NO_APP:-}" ] && printf "   or open %s/Zoomies.app" "$APPS" )"
