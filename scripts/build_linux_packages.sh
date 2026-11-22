#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)
    FLUTTER_ARCH="x64"
    DEB_ARCH="amd64"
    RPM_ARCH="x86_64"
    APPIMAGE_ARCH="x86_64"
    ;;
  aarch64|arm64)
    FLUTTER_ARCH="arm64"
    DEB_ARCH="arm64"
    RPM_ARCH="aarch64"
    APPIMAGE_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported Linux architecture: $HOST_ARCH" >&2
    exit 1
    ;;
esac

if [ "$(uname -s)" != "Linux" ]; then
  echo "build_linux_packages.sh must run on Linux (or inside Docker / GitHub Actions)." >&2
  exit 1
fi

VERSION="$(grep -E '^version:' "$ROOT_DIR/pubspec.yaml" | head -n1 | awk '{print $2}' | cut -d+ -f1)"
VERSION="${VERSION:-1.0.0}"

DIST_DIR="$ROOT_DIR/dist/linux"
STAGE_DIR="$ROOT_DIR/build/linux_packaging/$APPIMAGE_ARCH"
rm -rf "$STAGE_DIR"
mkdir -p "$DIST_DIR" "$STAGE_DIR"

echo "==> Building Flutter Linux release bundle ($FLUTTER_ARCH, version $VERSION)..."
flutter --suppress-analytics config --enable-linux-desktop
flutter --suppress-analytics config --enable-web
flutter --suppress-analytics pub get
flutter --suppress-analytics build linux --release
flutter --suppress-analytics build web --release --no-web-resources-cdn --no-wasm-dry-run

BUNDLE_DIR="$ROOT_DIR/build/linux/$FLUTTER_ARCH/release/bundle"
if [ ! -x "$BUNDLE_DIR/sync_canvas_notebook" ]; then
  echo "Expected Flutter bundle binary not found at: $BUNDLE_DIR/sync_canvas_notebook" >&2
  exit 1
fi

echo "==> Embedding offline Web bundle into $BUNDLE_DIR/web..."
rm -rf "$BUNDLE_DIR/web"
mkdir -p "$BUNDLE_DIR/web"
cp -a "$ROOT_DIR/build/web/." "$BUNDLE_DIR/web/"
find "$BUNDLE_DIR/web" -type f \( \
  -name '.last_build_id' -o \
  -name '*.symbols' -o \
  -name 'skwasm*' -o \
  -name 'wimp*' \
\) -delete

for required_file in \
  "$BUNDLE_DIR/web/index.html" \
  "$BUNDLE_DIR/web/main.dart.js" \
  "$BUNDLE_DIR/web/flutter_bootstrap.js" \
  "$BUNDLE_DIR/web/canvaskit/canvaskit.wasm" \
  "$BUNDLE_DIR/web/pdfjs/pdf.min.mjs" \
  "$BUNDLE_DIR/web/pdfjs/pdf.worker.min.mjs"
do
  if [ ! -f "$required_file" ]; then
    echo "Required offline Web bundle file missing: $required_file" >&2
    exit 1
  fi
done
if ! grep -Eq '"useLocalCanvasKit"[[:space:]]*:[[:space:]]*true' "$BUNDLE_DIR/web/flutter_bootstrap.js"; then
  echo "flutter_bootstrap.js does not enable useLocalCanvasKit:true" >&2
  exit 1
fi

DESKTOP_FILE="$ROOT_DIR/packaging/linux/sync-canvas-notebook.desktop"
SVG_ICON="$ROOT_DIR/packaging/linux/sync-canvas-notebook.svg"
PNG_ICON="$ROOT_DIR/web/icons/Icon-512.png"

# ------------------------------------------------------------------------------
# 1. Build .deb package (Debian / Ubuntu / Mint / Deepin / UOS)
# ------------------------------------------------------------------------------
echo "==> Building .deb ($DEB_ARCH)..."
DEB_ROOT="$STAGE_DIR/deb"
mkdir -p \
  "$DEB_ROOT/DEBIAN" \
  "$DEB_ROOT/opt/sync-canvas-notebook" \
  "$DEB_ROOT/usr/bin" \
  "$DEB_ROOT/usr/share/applications" \
  "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps" \
  "$DEB_ROOT/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE_DIR/." "$DEB_ROOT/opt/sync-canvas-notebook/"
chmod +x "$DEB_ROOT/opt/sync-canvas-notebook/sync_canvas_notebook"

cat > "$DEB_ROOT/usr/bin/sync-canvas-notebook" <<'EOF'
#!/usr/bin/env sh
exec /opt/sync-canvas-notebook/sync_canvas_notebook "$@"
EOF
chmod 0755 "$DEB_ROOT/usr/bin/sync-canvas-notebook"

cp "$DESKTOP_FILE" "$DEB_ROOT/usr/share/applications/sync-canvas-notebook.desktop"
cp "$PNG_ICON" "$DEB_ROOT/usr/share/icons/hicolor/512x512/apps/sync-canvas-notebook.png"
cp "$SVG_ICON" "$DEB_ROOT/usr/share/icons/hicolor/scalable/apps/sync-canvas-notebook.svg"

INSTALLED_SIZE="$(du -sk "$DEB_ROOT/opt" "$DEB_ROOT/usr" | awk '{sum+=$1} END{print sum}')"
cat > "$DEB_ROOT/DEBIAN/control" <<EOF
Package: sync-canvas-notebook
Version: $VERSION
Section: editors
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $INSTALLED_SIZE
Maintainer: SyncCanvas <noreply@github.com>
Depends: libgtk-3-0 (>= 3.18) | libgtk-3-0t64, libglib2.0-0 (>= 2.50) | libglib2.0-0t64, libc6
Recommends: poppler-utils, zenity
Homepage: https://github.com/moyx782/notebook-gemini
Description: SyncCanvas Notebook - cross-platform real-time shared whiteboard
 Multi-page handwriting and whiteboard notebook with HLC-CRDT real-time sync,
 embedded local host mode, and LAN auto-discovery across Desktop, Tablet, and Phone.
EOF

DEB_OUT="$DIST_DIR/sync-canvas-notebook_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$DEB_ROOT" "$DEB_OUT"

# ------------------------------------------------------------------------------
# 2. Build .rpm package (Fedora / RHEL / Rocky / Alma / openSUSE)
# ------------------------------------------------------------------------------
echo "==> Building .rpm ($RPM_ARCH)..."
RPM_TOP="$STAGE_DIR/rpmbuild"
mkdir -p "$RPM_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

RPM_SRC_PAYLOAD="$STAGE_DIR/rpm_payload"
mkdir -p \
  "$RPM_SRC_PAYLOAD/opt/sync-canvas-notebook" \
  "$RPM_SRC_PAYLOAD/usr/bin" \
  "$RPM_SRC_PAYLOAD/usr/share/applications" \
  "$RPM_SRC_PAYLOAD/usr/share/icons/hicolor/512x512/apps" \
  "$RPM_SRC_PAYLOAD/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE_DIR/." "$RPM_SRC_PAYLOAD/opt/sync-canvas-notebook/"
chmod +x "$RPM_SRC_PAYLOAD/opt/sync-canvas-notebook/sync_canvas_notebook"
cp "$DEB_ROOT/usr/bin/sync-canvas-notebook" "$RPM_SRC_PAYLOAD/usr/bin/sync-canvas-notebook"
chmod 0755 "$RPM_SRC_PAYLOAD/usr/bin/sync-canvas-notebook"
cp "$DESKTOP_FILE" "$RPM_SRC_PAYLOAD/usr/share/applications/sync-canvas-notebook.desktop"
cp "$PNG_ICON" "$RPM_SRC_PAYLOAD/usr/share/icons/hicolor/512x512/apps/sync-canvas-notebook.png"
cp "$SVG_ICON" "$RPM_SRC_PAYLOAD/usr/share/icons/hicolor/scalable/apps/sync-canvas-notebook.svg"

SPEC_FILE="$RPM_TOP/SPECS/sync-canvas-notebook.spec"
cat > "$SPEC_FILE" <<EOF
%global debug_package %{nil}
%global _build_id_links none
%global __os_install_post %{nil}
%global __strip /bin/true

Name:           sync-canvas-notebook
Version:        $VERSION
Release:        1
Summary:        SyncCanvas Notebook - cross-platform real-time shared whiteboard
License:        MIT
URL:            https://github.com/moyx782/notebook-gemini
AutoReqProv:    no
Requires:       gtk3

%description
Multi-page handwriting and whiteboard notebook with HLC-CRDT real-time sync,
embedded local host mode, and LAN auto-discovery across Desktop, Tablet, and Phone.

%install
mkdir -p %{buildroot}
cp -a "$RPM_SRC_PAYLOAD/." %{buildroot}/

%files
%defattr(-,root,root,-)
/opt/sync-canvas-notebook
/usr/bin/sync-canvas-notebook
/usr/share/applications/sync-canvas-notebook.desktop
/usr/share/icons/hicolor/512x512/apps/sync-canvas-notebook.png
/usr/share/icons/hicolor/scalable/apps/sync-canvas-notebook.svg
EOF

rpmbuild \
  --define "_topdir $RPM_TOP" \
  --target "$RPM_ARCH" \
  -bb "$SPEC_FILE"

RPM_BUILT="$(find "$RPM_TOP/RPMS" -name '*.rpm' | head -n1)"
if [ -z "$RPM_BUILT" ] || [ ! -f "$RPM_BUILT" ]; then
  echo "RPM build output missing under $RPM_TOP/RPMS" >&2
  exit 1
fi
RPM_OUT="$DIST_DIR/sync-canvas-notebook-${VERSION}-1.${RPM_ARCH}.rpm"
cp "$RPM_BUILT" "$RPM_OUT"

# ------------------------------------------------------------------------------
# 3. Build .AppImage (Portable Linux Desktop Bundle)
# ------------------------------------------------------------------------------
echo "==> Building .AppImage ($APPIMAGE_ARCH)..."
APPDIR="$STAGE_DIR/AppDir"
mkdir -p \
  "$APPDIR/usr/lib/sync-canvas-notebook" \
  "$APPDIR/usr/bin" \
  "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/512x512/apps" \
  "$APPDIR/usr/share/icons/hicolor/scalable/apps"

cp -a "$BUNDLE_DIR/." "$APPDIR/usr/lib/sync-canvas-notebook/"
chmod +x "$APPDIR/usr/lib/sync-canvas-notebook/sync_canvas_notebook"

cat > "$APPDIR/AppRun" <<'EOF'
#!/usr/bin/env sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib/sync-canvas-notebook/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/lib/sync-canvas-notebook/sync_canvas_notebook" "$@"
EOF
chmod 0755 "$APPDIR/AppRun"

ln -sf "../lib/sync-canvas-notebook/sync_canvas_notebook" "$APPDIR/usr/bin/sync-canvas-notebook"
cp "$DESKTOP_FILE" "$APPDIR/sync-canvas-notebook.desktop"
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/sync-canvas-notebook.desktop"
cp "$PNG_ICON" "$APPDIR/sync-canvas-notebook.png"
cp "$PNG_ICON" "$APPDIR/.DirIcon"
cp "$PNG_ICON" "$APPDIR/usr/share/icons/hicolor/512x512/apps/sync-canvas-notebook.png"
cp "$SVG_ICON" "$APPDIR/usr/share/icons/hicolor/scalable/apps/sync-canvas-notebook.svg"

APPIMAGETOOL_BIN="$(command -v appimagetool || true)"
if [ -z "$APPIMAGETOOL_BIN" ]; then
  APPIMAGETOOL_BIN="/tmp/appimagetool-${APPIMAGE_ARCH}.AppImage"
  if [ ! -x "$APPIMAGETOOL_BIN" ]; then
    echo "Downloading appimagetool-${APPIMAGE_ARCH}.AppImage..."
    curl -fL --retry 3 -o "$APPIMAGETOOL_BIN" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${APPIMAGE_ARCH}.AppImage"
    chmod +x "$APPIMAGETOOL_BIN"
  fi
fi

APPIMAGE_OUT="$DIST_DIR/SyncCanvas_Notebook-${VERSION}-${APPIMAGE_ARCH}.AppImage"
ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL_BIN" --no-appstream "$APPDIR" "$APPIMAGE_OUT"
chmod +x "$APPIMAGE_OUT"

(
  cd "$DIST_DIR"
  sha256sum \
    "$(basename "$DEB_OUT")" \
    "$(basename "$RPM_OUT")" \
    "$(basename "$APPIMAGE_OUT")" > "SHA256SUMS-${APPIMAGE_ARCH}.txt"
)

echo "==> Done! Linux packages written to $DIST_DIR:"
ls -lh "$DEB_OUT" "$RPM_OUT" "$APPIMAGE_OUT"
