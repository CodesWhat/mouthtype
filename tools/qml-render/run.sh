#!/usr/bin/env bash
# Render QML cases to PNG without a compositor, in light and dark.
#   bash tools/qml-render/run.sh OUT_DIR [case-name ...]
# With no case names, every file in cases/ is rendered. Needs qmltestrunner (Qt 6 declarative) on PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:?Provide the output directory}
shift
mkdir -p "$out"
out=$(cd "$out" && pwd)

runner=
for candidate in qmltestrunner6 qmltestrunner-qt6 qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
  if command -v "$candidate" >/dev/null 2>&1; then runner=$candidate; break; fi
done
if [[ -z "$runner" ]]; then
  echo 'qmltestrunner not found. Install Qt 6 declarative (Arch: qt6-declarative).' >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stage a copy of the plugin and the cases so cases import the real components by relative path.
# The layer-shell attached properties (WlrLayershell.*) cannot exist without the compositor plugin, so those lines
# are blanked in the copy. Line numbers stay the same so QML errors still point at the real source.
mkdir -p "$work/stage"
cp -a "$repo/tools/omarchy-plugin" "$work/stage/plugin"
cp -a "$here/cases" "$work/stage/cases"
find "$work/stage/plugin" -name '*.qml' -exec perl -pi -e 's/^\s*WlrLayershell\.[A-Za-z.]+\s*:.*$//' {} +
# Qt 6.12 ships its own QtQuick `Color` singleton, which shadows the shell's qs.Commons Color for any file that
# imports plain `import QtQuick`. Pinning the import below 6.12 keeps the stub visible, as it is in the real shell.
find "$work/stage" -name '*.qml' -exec perl -pi -e 's/^import QtQuick\s*$/import QtQuick 6.8\n/' {} +
# The software scene graph cannot run shader effects, so MultiEffect comes from a stand-in that skips the tint.
find "$work/stage" -name '*.qml' -exec perl -pi -e 's/^import QtQuick\.Effects\s*$/import RenderEffects\n/' {} +

# Service.qml and Panel.qml resolve assets from $HOME/.config/omarchy/plugins/dstahl.mouthtype.
mkdir -p "$work/home/.config/omarchy/plugins"
ln -s "$work/stage/plugin" "$work/home/.config/omarchy/plugins/dstahl.mouthtype"

if (($# > 0)); then
  cases=("$@")
else
  cases=()
  for file in "$work"/stage/cases/*.qml; do
    name=$(basename "$file" .qml)
    cases+=("$name")
  done
fi

export QT_QPA_PLATFORM=offscreen
export QT_QUICK_BACKEND=software
export QML_XHR_ALLOW_FILE_READ=1
export QT_QPA_FONTDIR=${QT_QPA_FONTDIR:-/usr/share/fonts}

# Newer plugins carry a shared Theme singleton that probes the shell for a dark flag. The probe cannot see the stub
# (see the import pin above), so the wrapper pins the mode through Theme.forceDark when the design module exists.
design_import=
design_set=
if [[ -f "$work/stage/plugin/design/qmldir" ]]; then
  design_import="import \"file://$work/stage/plugin/design\" as ShellDesign"
fi

status=0
for name in "${cases[@]}"; do
  if [[ ! -f "$work/stage/cases/$name.qml" ]]; then
    echo "No such case: $name" >&2
    status=1
    continue
  fi
  for theme in light dark; do
    dark=false
    [[ "$theme" == dark ]] && dark=true
    test_file="$work/tst_${name}_${theme}.qml"
    [[ -n "$design_import" ]] && design_set="ShellDesign.Theme.forceDark = $dark"
    sed -e "s|@DESIGN_IMPORT@|$design_import|" \
        -e "s|@DESIGN_SET@|$design_set|" \
        -e "s|@CASEFILE@|$work/stage/cases/$name.qml|g" \
        -e "s|@CASE@|$name|g" \
        -e "s|@THEME@|$theme|g" \
        -e "s|@DARK@|$dark|g" \
        -e "s|@HOME@|$work/home|g" \
        -e "s|@OUT@|$out|g" \
        "$here/lib/tst_render.qml.in" > "$test_file"
    log="$out/$name-$theme.log"
    echo "render $name ($theme)"
    if ! timeout --kill-after=5s 90s "$runner" -import "$here/stubs" -input "$test_file" > "$log" 2>&1; then
      echo "FAILED: $name ($theme), see $log" >&2
      tail -20 "$log" >&2
      status=1
      continue
    fi
    # A component that loads but misbehaves only warns. Treat those as failures so a broken render is never green.
    if grep -E 'ReferenceError|TypeError|is not a type|Cannot assign|is not installed|Binding loop' "$log" > "$out/$name-$theme.errors.txt"; then
      echo "QML errors in $name ($theme):" >&2
      cat "$out/$name-$theme.errors.txt" >&2
      status=1
    else
      rm -f "$out/$name-$theme.errors.txt"
    fi
  done
done
exit "$status"
