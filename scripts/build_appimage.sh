#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="${PROJECT_ROOT}/tools"
APP_BASENAME="beampainter"
APP_VERSION="0_5"

if ! command -v cargo-appimage >/dev/null 2>&1; then
  echo "cargo-appimage not found. Install with: cargo install cargo-appimage" >&2
  exit 1
fi

if ! command -v appimagetool >/dev/null 2>&1; then
  if [[ -x "${TOOLS_DIR}/appimagetool.AppImage" ]]; then
    ln -sf "${TOOLS_DIR}/appimagetool.AppImage" "${TOOLS_DIR}/appimagetool"
    export PATH="${TOOLS_DIR}:${PATH}"
  else
    cat >&2 <<'EOF'
appimagetool not found.
Install one of these:
  1) system-wide: sudo apt install appimagetool
  2) local file:  ./tools/appimagetool.AppImage  (must be executable)

Example local setup:
  mkdir -p tools
  wget -O tools/appimagetool.AppImage \
    https://github.com/AppImage/AppImageKit/releases/latest/download/appimagetool-x86_64.AppImage
  chmod +x tools/appimagetool.AppImage
EOF
    exit 1
  fi
fi

if ! cargo appimage; then
  echo "AppImage/AppDir build failed." >&2
  exit 1
fi

appdir_bin="${PROJECT_ROOT}/target/rustlaser_candle_gui.AppDir/usr/bin/rustlaser_candle_gui"
script_bin="${PROJECT_ROOT}/${APP_BASENAME}_v${APP_VERSION}"
if [[ -x "${appdir_bin}" ]]; then
  cp "${appdir_bin}" "${script_bin}"
  chmod +x "${script_bin}"
  echo "Executable: ${script_bin}"
else
  echo "AppDir executable not found: ${appdir_bin}" >&2
  exit 1
fi

while IFS= read -r appimage; do
  target_dir="$(dirname "${appimage}")"
  target_file="${target_dir}/${APP_BASENAME}_v${APP_VERSION}.AppImage"
  if [[ "$(basename "${appimage}")" != ${APP_BASENAME}* ]]; then
    mv "${appimage}" "${target_file}"
    echo "AppImage: ${target_file}"
  else
    echo "AppImage: ${appimage}"
  fi
done < <(find "${PROJECT_ROOT}/target" -maxdepth 3 -type f -name '*.AppImage' -print)
