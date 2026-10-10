#!/bin/sh
# notproton compatibility tool shim (CrossOver or a self-built Wine runner)
set -e

verb="$1"
shift || true

# Options set from the Compatibility page are passed along as
# launch options.
launch_env=""
argc=$#
argi=0
while [ "$argi" -lt "$argc" ]; do
  arg="$1"
  shift
  case "$arg" in
    CX_GRAPHICS*=*|D3DM_*=*|DXMT_*=*|DXVK_*=*|MTL_*=*|NOTPROTON_*=*|ROSETTA_*=*|WINE*=*)
      # shellcheck disable=SC2163 # arg is a NAME=VALUE pair, which export takes as an assignment
      export "$arg"
      launch_env="$launch_env $arg"
      ;;
    *) set -- "$@" "$arg" ;;
  esac
  argi=$((argi+1))
done

# Global defaults for every game: KEY=VALUE lines in global.env, same name rules as the
# launch options; a game's own launch options win.
global_env="$HOME/Library/Application Support/notproton/global.env"
if [ -r "$global_env" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CX_GRAPHICS*=*|D3DM_*=*|DXMT_*=*|DXVK_*=*|MTL_*=*|NOTPROTON_*=*|ROSETTA_*=*|WINE*=*)
        name=${line%%=*}
        eval "isset=\${$name+x}"
        # shellcheck disable=SC2154 # eval assigns isset on the line above
        [ -n "$isset" ] && continue
        # shellcheck disable=SC2163 # line is a NAME=VALUE pair
        export "$line"
        launch_env="$launch_env $line"
        ;;
    esac
  done < "$global_env"
fi

case "$verb" in
  getcompatpath)
    printf '%s\n' "$STEAM_COMPAT_DATA_PATH"
    exit 0
    ;;
esac

CX_ROOT="$HOME/Library/Application Support/notproton/runners/current"
export CX_ROOT
# cxcompatdb resolves its database through CX_HOME and logs an error for
# every module loaded without it :(
export CX_HOME="$HOME/Library/Application Support/CrossOver"
wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
WINESERVER="$CX_ROOT/bin/wineserver-arm64"
if [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
  wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
  WINELOADER="$wine_unix/wine"
  WINESERVER="$CX_ROOT/bin/wineserver"
  [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
fi
export WINELOADER WINESERVER
export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix"
export PATH="$CX_ROOT/bin:$PATH"

# A self-built runner (steamplay-mac) carries runner.json; its ntdll is patched in source,
# so there is no binary-patched copy in the bridge to compare against, and msync is on by
# default because its wineserver carries the msync fixes.
runner_kind=crossover
grep -q '"kind": "selfbuilt"' "$CX_ROOT/runner.json" 2>/dev/null && runner_kind=selfbuilt
msync_default=0
[ "$runner_kind" = selfbuilt ] && msync_default=1

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  log="$STEAM_COMPAT_DATA_PATH/notproton-run.log"
else
  log=/dev/null
fi
[ "$(stat -f %z "$log" 2>/dev/null || echo 0)" -gt 262144 ] \
  && : > "$log" || true
{
  echo "=== notproton run $(date) ==="
  echo "verb=$verb"
  echo "args:"; for a in "$@"; do echo "  [$a]"; done
  echo "cwd=$(pwd)"
  echo "STEAM_COMPAT_DATA_PATH=$STEAM_COMPAT_DATA_PATH"
  echo "STEAM_COMPAT_INSTALL_PATH=$STEAM_COMPAT_INSTALL_PATH"
  echo "STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID"
  echo "runner=$(readlink "$CX_ROOT" 2>/dev/null || echo "$CX_ROOT") kind=$runner_kind"
  echo "-- steam env passed through --"
  env | grep -iE '^(Steam|SDL_)' | sort
} >> "$log" 2>&1 || true

stage_step="startup"
# shellcheck disable=SC2329 # the trap below invokes this
report_early_exit() {
  status=$?
  [ "$status" = 0 ] && return 0
  echo "=== aborted during $stage_step (exit $status) before launch ===" \
    >> "$log" 2>&1 || true
}
trap report_early_exit EXIT

while :; do
  case "$STEAM_COMPAT_INSTALL_PATH" in
    ?*/) STEAM_COMPAT_INSTALL_PATH="${STEAM_COMPAT_INSTALL_PATH%/}" ;;
    *) break ;;
  esac
done
export STEAM_COMPAT_INSTALL_PATH

app_id="$STEAM_COMPAT_APP_ID"
case "$app_id" in ''|0) app_id="$SteamAppId" ;; esac
case "$app_id" in ''|0) app_id=$(basename "$STEAM_COMPAT_DATA_PATH" 2>/dev/null) ;; esac
case "$app_id" in ''|*[!0-9]*) app_id=0 ;; esac
echo "app_id=$app_id (STEAM_COMPAT_APP_ID=$STEAM_COMPAT_APP_ID)" >> "$log" 2>&1 || true

[ -n "$SteamAppId" ] || export SteamAppId="$app_id"
[ -n "$SteamGameId" ] || export SteamGameId="$app_id"

prefix_machine() {
  dll="$WINEPREFIX/drive_c/windows/system32/ntdll.dll"
  [ -f "$dll" ] || return 1
  off=$(od -A n -t u4 -j 60 -N 4 "$dll" 2>/dev/null | tr -d ' ')
  case "$off" in ''|*[!0-9]*) return 1 ;; esac
  sig=$(od -A n -t x1 -j "$off" -N 4 "$dll" 2>/dev/null | tr -d ' \n')
  [ "$sig" = 50450000 ] || return 1
  od -A n -t x2 -j "$((off + 4))" -N 2 "$dll" 2>/dev/null | tr -d ' \n'
}

tool_name() {
  case "$1" in
    aa64) printf 'the FEX build of CrossOver' ;;
    8664) printf 'the Rosetta build of CrossOver' ;;
    *) printf 'an older 32-bit setup' ;;
  esac
}

refuse_foreign_prefix() {
  case "${wine_unix##*/}" in
    aarch64-unix) want=aa64 ;;
    *) want=8664 ;;
  esac
  have=$(prefix_machine) || return 0
  [ "$have" = "$want" ] && return 0
  echo "=== prefix ntdll is $have and this compatibility tool wants $want, rebuild the prefix in NotProton ===" >> "$log" 2>&1 || true

  if [ "$verb" != run ]; then
    osascript >/dev/null 2>&1 <<APPLESCRIPT || true
display alert "This game needs its prefix rebuilt" message "This game originally ran under $(tool_name "$have"), but $(tool_name "$want") is present now. The prefix needs to be rebuilt in NotProton in order to run the game. You will not lose game saves by rebuilding the prefix." as critical
APPLESCRIPT
  fi
  exit 1
}
# Steam cloud related
merge_user_dir() {
  src=$1
  dst=$2
  failed=
  set -- ""
  while [ "$#" -gt 0 ]; do
    rest=$1
    shift
    src_dir="$src$rest"
    dst_dir="$dst$rest"
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then failed=1; continue; fi
    if [ -L "$dst_dir" ] && [ ! -e "$dst_dir" ]; then
      rm -f "$dst_dir" 2>/dev/null || true
    fi
    probe=$dst_dir
    through=
    while [ -n "$probe" ] && [ "$probe" != "$dst" ]; do
      if [ -L "$probe" ]; then through=1; break; fi
      probe=${probe%/*}
    done
    if [ -n "$through" ]; then
      echo "=== $rest is held by a link, merge refused ===" >> "$log" 2>&1 || true
      failed=1
      continue
    fi
    if [ -n "$rest" ] && [ -e "$dst_dir" ]; then continue; fi
    if ! mkdir -p "$dst_dir" 2>/dev/null; then failed=1; continue; fi
    for entry in "$src_dir"/* "$src_dir"/.[!.]* "$src_dir"/..?*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      if [ -d "$entry" ] && [ ! -L "$entry" ]; then
        set -- "$@" "$rest/$name"
        continue
      fi
      landing="$dst_dir/$name"
      if [ -e "$landing" ]; then continue; fi
      if [ -L "$landing" ]; then rm -f "$landing" 2>/dev/null || true; fi
      if [ -L "$entry" ]; then
        if ! cp -Pp "$entry" "$landing" 2>/dev/null; then
          rm -f "$landing" 2>/dev/null || true
          failed=1
        fi
      else
        if ! cp -p "$entry" "$landing" 2>/dev/null; then
          rm -f "$landing" 2>/dev/null || true
          failed=1
        fi
        chmod u+w "$landing" 2>/dev/null || true
      fi
    done
  done
  [ -z "$failed" ]
}

# Steam Cloud stuff
migrate_user_paths() {
  profile=$1
  for pair in \
    "Local Settings/Application Data|AppData/Local|../AppData/Local" \
    "Application Data|AppData/Roaming|./AppData/Roaming" \
    "My Documents|Documents|./Documents"; do
    old_rel=${pair%%|*}
    rest=${pair#*|}
    new_rel=${rest%%|*}
    link=${rest#*|}
    old="$profile/$old_rel"
    new="$profile/$new_rel"
    case "$(readlink "$new" 2>/dev/null || true)" in
      *"drive_c/users/steamuser/$old_rel") rm -f "$new" 2>/dev/null || true ;;
    esac
    if [ -L "$new" ]; then
      echo "=== $new_rel is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      continue
    fi
    held=
    for rel in "$old_rel" "$new_rel"; do
      probe=$rel
      while [ "$probe" != "${probe%/*}" ]; do
        probe=${probe%/*}
        if [ -L "$profile/$probe" ]; then held=$probe; break; fi
      done
      if [ -n "$held" ]; then break; fi
    done
    if [ -n "$held" ]; then
      echo "=== $held is a link, rebuild the prefix for cloud saves ===" \
        >> "$log" 2>&1 || true
      continue
    fi
    if [ -e "$old" ] && [ ! -L "$old" ]; then
      if ! merge_user_dir "$old" "$new"; then
        echo "=== $old_rel did not merge into $new_rel, left in place ===" \
          >> "$log" 2>&1 || true
        continue
      fi
      rmdir "$old BACKUP" 2>/dev/null || true
      if [ -e "$old BACKUP" ] || [ -L "$old BACKUP" ] \
        || ! mv "$old" "$old BACKUP" 2>> "$log"; then
        echo "=== $old_rel could not be moved aside, cloud saves stay split ===" \
          >> "$log" 2>&1 || true
        continue
      fi
    fi
    if [ ! -e "$old" ] && [ ! -L "$old" ]; then
      mkdir -p "${old%/*}" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    elif [ -L "$old" ] && [ "$(readlink "$old")" != "$link" ]; then
      rm -f "$old" 2>/dev/null || true
      ln -s "$link" "$old" 2>/dev/null \
        || echo "=== $old_rel could not be aliased onto $new_rel ===" >> "$log" 2>&1 \
        || true
    fi
  done
}

lay_out_proton_profile() {
  users="$WINEPREFIX/drive_c/users"
  if [ -d "$users/crossover" ] && [ ! -L "$users/crossover" ]; then
    echo "=== prefix predates the steamuser layout, rebuild it for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  profile="$users/steamuser"
  if [ -L "$profile" ]; then
    echo "=== the profile is a link, rebuild the prefix for cloud saves ===" \
      >> "$log" 2>&1 || true
    return 0
  fi
  mkdir -p "$profile" 2>/dev/null || return 0
  for folder in Documents Desktop Downloads Music Pictures Videos Templates \
      AppData/Local AppData/Roaming; do
    mkdir -p "$profile/$folder" 2>/dev/null || true
  done
  migrate_user_paths "$profile"
  if [ -L "$users/crossover" ] && [ ! -e "$users/crossover" ]; then
    rm -f "$users/crossover" 2>/dev/null || true
  fi
  if [ ! -e "$users/crossover" ] \
    && ln -s steamuser "$users/crossover" 2>/dev/null; then
    echo "=== pointed crossover at steamuser ===" >> "$log" 2>&1 || true
  fi
}

if [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
  export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
  mkdir -p "$WINEPREFIX"
  msync_from=launch-options
  if [ -z "$WINEMSYNC" ] && [ -r "$STEAM_COMPAT_DATA_PATH/notproton-msync" ]; then
    WINEMSYNC=$(tr -d ' \t\n' \
      < "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true)
    msync_from=carried-over
  fi
  [ -n "$WINEMSYNC" ] || msync_from=default
  export WINEMSYNC="${WINEMSYNC:-$msync_default}"
  printf '%s' "$WINEMSYNC" \
    > "$STEAM_COMPAT_DATA_PATH/notproton-msync" 2>/dev/null || true
  stage_step="prefix arch check"
  refuse_foreign_prefix
  echo "sync: WINEMSYNC=$WINEMSYNC from $msync_from" >> "$log" 2>&1 || true
  "$WINESERVER" -k >> "$log" 2>&1 || true
  stage_step="profile layout"
  lay_out_proton_profile
  "$WINELOADER" wineboot --init >> "$log" 2>&1 || true
  "$WINELOADER" reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' /v Auto /t REG_SZ /d 0 /f >> "$log" 2>&1 || true
  "$WINELOADER" reg add 'HKLM\Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug' /v Auto /t REG_SZ /d 0 /f >> "$log" 2>&1 || true
  "$WINELOADER" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >> "$log" 2>&1 || true

  echo "video: RetinaMode=${NOTPROTON_RETINA:-0}" >> "$log" 2>&1 || true
  if [ "$NOTPROTON_RETINA" = "1" ]; then
    "$WINELOADER" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d y /f >> "$log" 2>&1 || true
  else
    "$WINELOADER" reg delete 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /f >> "$log" 2>&1 || true
  fi

  "$WINELOADER" reg add 'HKLM\Software\Classes\steam' /v 'URL Protocol' /t REG_SZ /d '' /f >> "$log" 2>&1 || true
  "$WINELOADER" reg add 'HKLM\Software\Classes\steam\shell\open\command' /ve /t REG_SZ /d '"C:\Program Files (x86)\Steam\steam.exe" "%1"' /f >> "$log" 2>&1 || true
fi

bridge_src="$HOME/Library/Application Support/notproton/bridge"
prefix_steam="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
verify_runner() {
  if [ "$runner_kind" = selfbuilt ]; then
    :
  elif [ ! -d "$bridge_src/wine" ]; then
    echo "=== no patched ntdll in the bridge, run NotProton ===" >> "$log" 2>&1 || true
    return
  fi
  [ "$runner_kind" = selfbuilt ] || for arch in x86_64-windows i386-windows aarch64-windows; do
    staged="$bridge_src/wine/$arch/ntdll.dll"
    live="$CX_ROOT/lib/wine/$arch/ntdll.dll"
    [ -f "$staged" ] || continue
    if [ ! -f "$live" ]; then
      echo "=== runner has no $arch ntdll, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    elif ! cmp -s "$staged" "$live"; then
      echo "=== runner $arch ntdll is not the patched copy, set up the runner in NotProton ===" >> "$log" 2>&1 || true
    fi
  done
  for arch in i386-windows x86_64-windows "${wine_unix##*/}"; do
    case "$arch" in
      *-unix) name="lsteamclient.so" ;;
      *) name="lsteamclient.dll" ;;
    esac
    [ -f "$CX_ROOT/lib/wine/$arch/$name" ] && continue
    echo "=== runner is missing $arch/$name, set up the runner in NotProton ===" >> "$log" 2>&1 || true
  done
}
install_lsteamclient_trigger() {
  src="$bridge_src/i386-windows/lsteamclient.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/lsteamclient.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if cp -f "$src" "$dst"; then
    echo "=== installed syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  else
    echo "=== could not install the syswow64 lsteamclient trigger ===" >> "$log" 2>&1 || true
  fi
}

# A fix to match Proton
install_legacy_steam_dll() {
  src="$bridge_src/legacycompat/Steam.dll"
  dst="$WINEPREFIX/drive_c/windows/syswow64/Steam.dll"
  [ -f "$src" ] && [ -d "$WINEPREFIX/drive_c/windows/syswow64" ] || return 0
  cmp -s "$src" "$dst" && return 0
  if cp -f "$src" "$dst"; then
    echo "=== installed legacy Steam.dll ===" >> "$log" 2>&1 || true
  else
    echo "=== could not install the legacy Steam.dll ===" >> "$log" 2>&1 || true
  fi
}

# Steam runs a Windows game's installscript.vdf by invoking the standalone
# evaluator through the compat tool, the same way the linux client does, but
# the binaries are missing on macOS, so...
install_legacycompat() {
  src="$bridge_src/legacycompat"
  dst="$STEAM_COMPAT_CLIENT_INSTALL_PATH/legacycompat"
  [ -d "$src" ] && [ -n "$STEAM_COMPAT_CLIENT_INSTALL_PATH" ] || return 0
  mkdir -p "$dst" || return 0
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    cmp -s "$f" "$dst/$b" && continue
    cp -f "$f" "$dst/$b" && \
      echo "=== installed legacycompat/$b ===" >> "$log" 2>&1
  done
}

bridge_files="steamclient64.dll steamclient.dll tier0_s64.dll vstdlib_s64.dll"
bridge_files="$bridge_files lsteamclient.dll lsteamclient.so steam.exe"
if [ -d "$bridge_src" ] && [ -n "$WINEPREFIX" ]; then
  stage_step="bridge staging"
  mkdir -p "$prefix_steam"
  for f in $bridge_files; do
    src="$bridge_src/$f"
    if [ "$f" = lsteamclient.so ]; then
      src="$bridge_src/${wine_unix##*/}/$f"
    fi
    if [ ! -f "$src" ]; then
      echo "=== bridge missing $f ===" >> "$log" 2>&1 || true
      continue
    fi
    cp -f "$src" "$prefix_steam/$f" || \
      echo "=== failed to stage $f ===" >> "$log" 2>&1
  done
  for f in "$prefix_steam"/*.dll "$prefix_steam"/*.so "$prefix_steam"/*.exe; do
    [ -f "$f" ] || continue
    case " $bridge_files " in
      *" $(basename "$f") "*) ;;
      *) rm -f "$f" && echo "=== pruned stale $(basename "$f") ===" >> "$log" 2>&1 ;;
    esac
  done
  verify_runner
  install_lsteamclient_trigger
  install_legacy_steam_dll
  export WINEDLLPATH="$prefix_steam:$WINEDLLPATH"
  export WINEDLLOVERRIDES="steamclient=n;steamclient64=n;lsteamclient=b"
  native_client="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
  if [ -z "$native_client" ]; then
    native_client="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$native_client"
  fi
  install_legacycompat
  echo "=== bridge staged into $prefix_steam ===" >> "$log" 2>&1 || true
  echo "WINEDLLPATH=$WINEDLLPATH" >> "$log" 2>&1 || true
  echo "STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_COMPAT_CLIENT_INSTALL_PATH" >> "$log" 2>&1 || true
fi

# Graphics backend. CX_GRAPHICS_BACKEND (the options panel's launch option) wins; otherwise a
# self-built runner picks by what the game's binaries import: Direct3D 12 -> D3DMetal,
# Direct3D 10/11 -> DXMT, anything else -> wined3d. CrossOver runners keep their own logic.
pe_d3d="$HOME/Library/Application Support/notproton/pe-d3d"
detect_d3d() {
  [ -x "$pe_d3d" ] && [ -d "$STEAM_COMPAT_INSTALL_PATH" ] || { echo none; return; }
  # A game that ships Microsoft's D3D12 Agility SDK renders with Direct3D 12.
  if find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 6 -ipath '*/D3D12/D3D12Core.dll' 2>/dev/null | grep -q .; then
    echo "  hint: bundled D3D12 Agility SDK" >> "$log" 2>&1 || true
    echo d3d12
    return
  fi
  # the launch target plus the largest executables (a launcher stub often fronts the
  # real *-Shipping.exe), and the engine DLLs that do the rendering (Unity, CryEngine...)
  candidates=$(
    { [ -f "$1" ] && printf '%s\n' "$1"
      find "$STEAM_COMPAT_INSTALL_PATH" -maxdepth 6 -type f \( -iname '*.exe' -o -iname 'UnityPlayer.dll' \
          -o -iname '*render*.dll' -o -iname '*d3d1[12]*.dll' -o -iname 'CryRenderD3D*.dll' \) -size +200k 2>/dev/null \
        | grep -viE '/(_commonredist|commonredist|redist|redistributables|directx|vcredist|dotnet|support|easyanticheat|battleye|__installer|installers?|crashreport[a-z]*)/' \
        | grep -viE '/d3d12/(d3d12core|d3d12sdklayers)\.dll$' \
        | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %z "$f")" "$f"; done \
        | sort -rn | head -12 | cut -f2-
    } | awk '!seen[$0]++')
  [ -n "$candidates" ] || { echo none; return; }
  scan=$(printf '%s\n' "$candidates" | tr '\n' '\0' | xargs -0 "$pe_d3d" 2>/dev/null)
  printf '%s\n' "$scan" | sed 's/^/  pe-d3d: /' >> "$log" 2>&1 || true
  flags=$(printf '%s\n' "$scan" | cut -d' ' -f1 | tr ',\n' '  ')
  # Engines that load their renderer at run time (Unreal Engine 5 among them) import no
  # Direct3D DLL at all; the names of the runtimes in the largest binary are the best
  # remaining hint.
  case " $flags " in
    *" d3d"*|*" dxgi:"*|*" ddraw:"*|*" opengl:"*|*" vulkan:"*) ;;
    *)
      if :; then
        big=$(printf '%s\n' "$candidates" | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -f %z "$f")" "$f"; done \
          | sort -rn | head -1 | cut -f2-)
        if [ -f "$big" ]; then
          if LC_ALL=C grep -a -q -i 'd3d12\.dll' "$big"; then flags="$flags d3d12:d"
          elif LC_ALL=C grep -a -q -i 'd3d11\.dll' "$big"; then flags="$flags d3d11:d"
          elif LC_ALL=C grep -a -q -i 'd3d9\.dll' "$big"; then flags="$flags d3d9:d"
          fi
          echo "  hint: runtime names in $(basename "$big"): $flags" >> "$log" 2>&1 || true
        fi
      fi
      ;;
  esac
  case " $flags " in
    *" d3d12:i "*) echo d3d12 ;;
    *" d3d11:i "*|*" dxgi:i "*|*" d3d10:i "*) echo d3d11 ;;
    *" d3d12:d "*) echo d3d12 ;;
    *" d3d11:d "*|*" dxgi:d "*|*" d3d10:d "*) echo d3d11 ;;
    *" d3d9:"*|*" d3d8:"*|*" ddraw:"*) echo d3d9 ;;
    *" opengl:"*) echo opengl ;;
    *" vulkan:"*) echo vulkan ;;
    *) echo none ;;
  esac
}
if [ "$runner_kind" = selfbuilt ]; then
  backend="${CX_GRAPHICS_BACKEND:-auto}"
  backend_from=launch-options
  if [ "$backend" = auto ]; then
    api=$(detect_d3d "$1")
    case "$api" in
      d3d12) backend=d3dmetal ;;
      d3d11) backend=dxmt ;;
      *) backend=wined3d ;;
    esac
    backend_from="auto ($api)"
  fi
  case "$backend" in
    d3dmetal)
      export WINEDLLPATH_PREPEND="$CX_ROOT/lib/renderers/d3dmetal"
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib/external/libd3dshared.dylib"
      ;;
    dxmt)
      export WINEDLLPATH_PREPEND="$CX_ROOT/lib/renderers/dxmt"
      ;;
    dxvk)
      if [ -d "$CX_ROOT/lib/renderers/dxvk" ]; then
        export WINEDLLPATH_PREPEND="$CX_ROOT/lib/renderers/dxvk"
      else
        echo "=== no DXVK in this runner, using wined3d ===" >> "$log" 2>&1 || true
        backend=wined3d
      fi
      ;;
    *) backend=wined3d ;;
  esac
  export CX_ACTIVE_GRAPHICS_BACKEND="$backend"
  echo "graphics: $backend from $backend_from" >> "$log" 2>&1 || true
fi

# Apple's Metal Performance HUD: when it is on and nothing else is configured, keep it small
# in the top-right corner with just the frame rate and frame time.
# Below it, syshud adds what Metal cannot show (CPU/GPU load, RAM, OS, runner, backend);
# NOTPROTON_SYSHUD=0 leaves it out.
syshud_pid=""
if [ "${MTL_HUD_ENABLED:-0}" = 1 ]; then
  export MTL_HUD_ALIGNMENT="${MTL_HUD_ALIGNMENT:-topright}"
  export MTL_HUD_SCALE="${MTL_HUD_SCALE:-0.12}"
  export MTL_HUD_OPACITY="${MTL_HUD_OPACITY:-0.85}"
  export MTL_HUD_ELEMENTS="${MTL_HUD_ELEMENTS:-fps,frameinterval,gputime,presentdelay,layersize,memory,fpsgraph}"
  echo "hud: $MTL_HUD_ALIGNMENT scale=$MTL_HUD_SCALE elements=$MTL_HUD_ELEMENTS" >> "$log" 2>&1 || true
  syshud="$HOME/Library/Application Support/notproton/syshud"
  if [ "${NOTPROTON_SYSHUD:-1}" = 1 ] && [ -x "$syshud" ] && [ "$verb" != run ]; then
    rows=$(printf '%s' "$MTL_HUD_ELEMENTS" | tr ',' '\n' | grep -c .)
    case ",$MTL_HUD_ELEMENTS," in *graph*|*histogram*) rows=$((rows + 3)) ;; esac
    wine_label="$(sed -n 's/.*"wine": "\(.*\)".*/\1/p' "$CX_ROOT/runner.json" 2>/dev/null) ($(readlink "$CX_ROOT" 2>/dev/null || echo runner))"
    "$syshud" --offset "${NOTPROTON_SYSHUD_OFFSET:-$((14 + rows * 14))}" \
      --label "Wine: $wine_label" --label "Graphics: ${backend:-${CX_ACTIVE_GRAPHICS_BACKEND:-?}} (Rosetta)" \
      --pid $$ --app "com.notproton.launcher.$app_id" >> "$log" 2>&1 &
    syshud_pid=$!
  fi
fi

export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all}"
trap - EXIT
echo "launch_env=$launch_env" >> "$log" 2>&1 || true
echo "=== launching ($verb): $WINELOADER $* ===" >> "$log" 2>&1 || true

target="$1"
case "$target" in
  "$STEAM_COMPAT_INSTALL_PATH"/*) foreground=1 ;;
  *) foreground=0 ;;
esac

if [ "$foreground" = 0 ]; then
  echo "=== running helper on raw loader: $* ===" >> "$log" 2>&1 || true
  "$WINELOADER" "$@" >> "$log" 2>&1
  status=$?
  echo "=== helper exited status=$status ===" >> "$log" 2>&1 || true
  exit $status
fi

# Fixes CrossOver window focus issues
steam_root="$(dirname "$(dirname "$(dirname "$STEAM_COMPAT_DATA_PATH")")")"
manifest="$steam_root/steamapps/appmanifest_$app_id.acf"
client_root="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
while [ -n "$client_root" ] && [ "$client_root" != "/" ] && [ ! -d "$client_root/appcache" ]; do
  client_root=$(dirname "$client_root")
done
# Icon stuff
appinfo_tool="$HOME/Library/Application Support/notproton/appinfo"
appinfo_vdf="$client_root/appcache/appinfo.vdf"
meta_name=""
meta_icon=""
meta_clienticon=""
if [ -x "$appinfo_tool" ] && [ -f "$appinfo_vdf" ]; then
  meta=$("$appinfo_tool" "$appinfo_vdf" "$app_id" 2>> "$log") || meta=""
  meta_name=$(printf '%s\n' "$meta" | sed -n 's/^name=//p')
  meta_icon=$(printf '%s\n' "$meta" | sed -n 's/^icon=//p')
  meta_clienticon=$(printf '%s\n' "$meta" | sed -n 's/^clienticon=//p')
fi
game_name="$meta_name"
if [ -z "$game_name" ] && [ -f "$manifest" ]; then
  game_name=$(sed -n 's/.*"name"[[:space:]]*"\(.*\)".*/\1/p' "$manifest" | head -1)
fi
[ -z "$game_name" ] && game_name=$(basename "$STEAM_COMPAT_INSTALL_PATH")
[ -z "$game_name" ] && game_name="Steam Game"
# shellcheck disable=SC1003 # the pair deletes a literal backslash, not a quote
bundle_name=$(printf '%s' "$game_name" | tr -d '/:"`$\\')
game_name_xml=$(printf '%s' "$game_name" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
loader_root="$HOME/Library/Application Support/notproton/launchers/$app_id"
mkdir -p "$loader_root"
loader_app="$loader_root/$bundle_name.app"
rm -rf "$loader_root"/*.app
loader_contents="$loader_app/Contents"
loader_macos="$loader_contents/MacOS"
loader_res="$loader_contents/Resources"
mkdir -p "$loader_macos" "$loader_res"

icon_arg=""
resolve_icon() {
  set +e
  iconmaker="$HOME/Library/Application Support/notproton/iconmaker"
  art_dir="$client_root/appcache/librarycache/$app_id"
  art=""
  if [ -n "$meta_clienticon" ]; then
    ico="$loader_root/clienticon-$meta_clienticon.ico"
    absent="$loader_root/clienticon-$meta_clienticon.absent"
    find "$loader_root" -maxdepth 1 -name 'clienticon-*'   ! -name "clienticon-$meta_clienticon.*" -delete 2>/dev/null || true
    find "$absent" -mtime +14 -delete 2>/dev/null || true
    if [ ! -s "$ico" ] && [ ! -f "$absent" ]; then
      url="https://shared.fastly.steamstatic.com/community_assets/images/apps/$app_id/$meta_clienticon.ico"
      code=$(curl -fsL --connect-timeout 5 --max-time 20 -w '%{http_code}' -o "$ico.new" "$url" 2>>"$log")
      magic=$(od -An -tx1 -N4 "$ico.new" 2>/dev/null | tr -d ' \n')
      if [ "$magic" = "00000100" ]; then
        mv -f "$ico.new" "$ico"
        echo "fetched client icon $meta_clienticon" >> "$log" 2>&1 || true
      else
        rm -f "$ico.new"
        if [ "$code" = "404" ]; then
          : > "$absent"
          echo "no client icon published for $meta_clienticon" >> "$log" 2>&1 || true
        else
          echo "client icon fetch for $meta_clienticon failed (http ${code:-none}), will retry" >> "$log" 2>&1 || true
        fi
      fi
    fi
    [ -s "$ico" ] && art="$ico"
  fi
  if [ -z "$art" ] && [ -n "$meta_icon" ] && [ -f "$art_dir/$meta_icon.jpg" ]; then
    art="$art_dir/$meta_icon.jpg"
  fi
  if [ -z "$art" ]; then
    art=$(find "$art_dir" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null |   grep -E '/[0-9a-f]{40}\.jpg$' | head -1)
  fi
  # Capsule art (horrible) fallback if no icon at all exists...
  if [ -z "$art" ]; then
    for name in library_600x900.jpg header.jpg; do
      found=$(find "$art_dir" -name "$name" 2>/dev/null | head -1)
      [ -n "$found" ] && { art="$found"; break; }
    done
  fi
  # non-Steam shortcuts have no art, so (as a temporary measure while I think of
  # better ways to solve for this) let's use the icon in the EXE itself instead.
  if [ -z "$art" ] && [ -f "$target" ]; then
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
      *.exe) art="$target" ;;
    esac
  fi
  icon_source=""
  if [ -n "$art" ]; then
    icon_source="$art $(stat -f %m "$art" 2>/dev/null || echo 0)"
  fi
  icon_cache="$loader_root/game.icns"
  if [ -n "$art" ] && [ -s "$icon_cache" ] &&   [ "$(cat "$loader_root/notproton-icon.source" 2>/dev/null)" =   "$icon_source" ] && cp -f "$icon_cache" "$loader_res/game.icns"; then
    icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
    echo "icon reused from $art" >> "$log" 2>&1 || true
  elif [ -n "$art" ] && [ -x "$iconmaker" ]; then
    if "$iconmaker" "$art" "$icon_cache" >> "$log" 2>&1 &&   cp -f "$icon_cache" "$loader_res/game.icns"; then
      icon_arg="  <key>CFBundleIconFile</key><string>game</string>"
      printf '%s\n' "$icon_source" > "$loader_root/notproton-icon.source"
      echo "icon built from $art" >> "$log" 2>&1 || true
    elif [ "$art" = "$ico" ]; then
      # A cached .ico that iconmaker rejects is corrupt and passes the size
      # guard on every launch, so drop it to force a clean fetch next time.
      rm -f "$ico"
      echo "discarded unreadable client icon $meta_clienticon" >> "$log" 2>&1 || true
    fi
  fi
  set -e
  return 0
}
resolve_icon || true
[ -n "$icon_arg" ] || echo "no icon resolved, launching without one" >> "$log" 2>&1 || true

uielement_arg=""
if [ "${NOTPROTON_HIDE_LAUNCHER_TILE:-0}" = "1" ]; then
  uielement_arg="  <key>LSUIElement</key><true/>"
  echo "launcher tile hidden by NOTPROTON_HIDE_LAUNCHER_TILE" >> "$log" 2>&1 || true
fi
cat > "$loader_contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$game_name_xml</string>
  <key>CFBundleDisplayName</key><string>$game_name_xml</string>
  <key>CFBundleIdentifier</key><string>com.notproton.launcher.$app_id</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$uielement_arg
$icon_arg
</dict>
</plist>
PLIST

# Invokes macOS Game Mode
for f in "$wine_unix"/*; do
  [ -e "$f" ] || continue
  base=${f##*/}
  case "$base" in
    wine|wine.app) continue ;;
  esac
  ln -sfn "$f" "$loader_macos/$base"
done
ln "$WINELOADER" "$loader_macos/wine" 2>/dev/null || cp "$WINELOADER" "$loader_macos/wine"
if [ -x "$loader_macos/wine" ]; then
  WINELOADER="$loader_macos/wine"
  echo "loader staged in bundle for game mode" >> "$log" 2>&1 || true
else
  echo "loader staging failed, game mode unavailable" >> "$log" 2>&1 || true
fi

cat > "$loader_macos/launcher" <<LAUNCHER
#!/bin/sh
export WINELOADER="$WINELOADER"
export DYLD_FALLBACK_LIBRARY_PATH="$CX_ROOT/lib:/usr/local/lib:/usr/lib"
wine_log="$loader_root/notproton-wine.log"
exec > "\$wine_log" 2>&1
shim="$HOME/Library/Application Support/notproton/overlay-shim.dylib"
if [ -n "\$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  if [ -f "\$shim" ]; then
    export DYLD_INSERT_LIBRARIES="\$shim:\$STEAM_DYLD_INSERT_LIBRARIES"
    export NOTPROTON_OVERLAY_SHIM="\$shim"
  else
    export DYLD_INSERT_LIBRARIES="\$STEAM_DYLD_INSERT_LIBRARIES"
  fi
fi
[ -n "\$NOTPROTON_GAME_CWD" ] && cd "\$NOTPROTON_GAME_CWD"
"$WINELOADER" "\$@"
exit \$?
LAUNCHER
chmod +x "$loader_macos/launcher"

wine_helpers='winedevice\.exe|services\.exe|plugplay\.exe|svchost\.exe'
wine_helpers="$wine_helpers|rpcss\.exe|explorer\.exe|steam\.exe"
wine_helpers="$wine_helpers|winemenubuilder\.exe|conhost\.exe|start\.exe"
wine_helpers="$wine_helpers|wineboot\.exe|rundll32\.exe|tabtip\.exe"
wine_helpers="$wine_helpers|vc_redist|vcredist|dxsetup\.exe|msiexec\.exe"
wine_helpers="$wine_helpers|installinf|iscriptevaluator\.exe|regsvr32\.exe"
wine_helpers="$wine_helpers|winedbg\.exe|unitycrashhandler"
prefix_server_dir() {
  [ -n "$WINEPREFIX" ] || return 1
  ids=$(stat -f '%d-%i' "$WINEPREFIX" 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  printf '/tmp/.wine-%s/server-%s' "$(id -u)" \
    "$(printf '%s' "$ids" | awk -F- '{printf "%x-%x", $1, $2}')"
}

prefix_game_running() {
  command -v lsof >/dev/null 2>&1 || return 1
  dir=$(prefix_server_dir) || return 1
  [ -d "$dir" ] || return 1
  pids=$(lsof -t +D "$dir" 2>/dev/null | sort -u | tr '\n' ',')
  pids=${pids%,}
  [ -n "$pids" ] || return 1
  # shellcheck disable=SC1003 # the pair matches the backslash in a drive path
  ps -p "$pids" -o args= 2>/dev/null | grep -E '^[A-Za-z]:\\' | grep -viE "$wine_helpers" | grep -q .
}

wait_prefix_idle() {
  idle=0
  tick=0
  while [ "$idle" -lt 10 ] && [ "$tick" -lt 300 ]; do
    tick=$((tick + 1))
    if prefix_game_running; then idle=0; else idle=$((idle + 1)); fi
    sleep 1
  done
  echo "wait_prefix_idle done after tick=$tick idle=$idle" >> "$log" 2>&1 || true
}

kill_wine_prefix() {
  "$WINESERVER" -k >> "$log" 2>&1 || true
  "$WINESERVER" -w >> "$log" 2>&1 || true
  if command -v lsof >/dev/null 2>&1 && server_dir=$(prefix_server_dir); then
    if [ -d "$server_dir" ]; then
      survivors=$(lsof -t +D "$server_dir" 2>/dev/null | sort -u)
      if [ -n "$survivors" ]; then
        echo "=== sweeping prefix stragglers: $survivors ===" >> "$log" 2>&1 || true
        # shellcheck disable=SC2086 # survivors is a list of pids and has to split
        kill -9 $survivors 2>/dev/null || true
      fi
    fi
  fi
}

# Steam's "Exit Game" and the client shutting the game down both send a
# termination signal to this run script, this handles it
# shellcheck disable=SC2329 # the trap below invokes this
terminate() {
  echo "=== termination signal received, killing wine prefix ===" >> "$log" 2>&1 || true
  kill_wine_prefix
  [ -n "$open_pid" ] && kill "$open_pid" 2>/dev/null || true
}
trap terminate TERM INT HUP

shim_exe="C:\\Program Files (x86)\\Steam\\steam.exe"

game_cwd="$(pwd)"
if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ]; then
  echo "=== overlay injected from $STEAM_DYLD_INSERT_LIBRARIES ===" >> "$log" 2>&1 || true
else
  echo "=== client staged no overlay renderer, overlay disabled ===" >> "$log" 2>&1 || true
fi
set -- --args "$shim_exe" "$@"
for name in $(env | sed -nE 's/^(Steam[A-Za-z0-9]*|WINEDLLPATH_PREPEND|(CX_GRAPHICS|CX_ACTIVE_GRAPHICS|CX_APPLEGPTK_|D3DM_|DXMT_|DXVK_|MTL_|ROSETTA_)[A-Z0-9_]*)=.*/\1/p'); do
  eval "value=\$$name"
  # shellcheck disable=SC2154 # eval assigns value on the line above
  set -- --env "$name=$value" "$@"
done
set -- \
  --env CX_ROOT="$CX_ROOT" \
  --env CX_HOME="$CX_HOME" \
  --env WINESERVER="$WINESERVER" \
  --env WINEDLLPATH="$WINEDLLPATH" \
  --env WINEDLLOVERRIDES="$WINEDLLOVERRIDES" \
  --env WINEMSYNC="$WINEMSYNC" \
  --env WINEPREFIX="$WINEPREFIX" \
  --env WINEDEBUG="$WINEDEBUG" \
  --env PATH="$PATH" \
  --env STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH" \
  --env STEAM_COMPAT_INSTALL_PATH="$STEAM_COMPAT_INSTALL_PATH" \
  --env STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH" \
  --env STEAM_COMPAT_APP_ID="$STEAM_COMPAT_APP_ID" \
  --env STEAM_DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES" \
  --env NOTPROTON_GAME_CWD="$game_cwd" "$@"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A"
lsregister="$lsregister/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$lsregister" ] && "$lsregister" -f "$loader_app" >> "$log" 2>&1 || true
open -n -W -a "$loader_app" "$@" >> "$log" 2>&1 &
open_pid=$!
status=0
seen=0
idle=0
while :; do
  if prefix_game_running; then
    seen=1
    idle=0
  else
    idle=$((idle + 1))
  fi
  if ! kill -0 "$open_pid" 2>/dev/null; then
    wait "$open_pid" || status=$?
    echo "=== bundle exited status=$status ===" >> "$log" 2>&1 || true
    if [ "$status" -le 128 ]; then
      wait_prefix_idle
    fi
    break
  fi
  if [ "$seen" -eq 1 ] && [ "$idle" -ge 10 ]; then
    echo "=== game tree gone, ending session ===" >> "$log" 2>&1 || true
    break
  fi
  sleep 1
done
echo "=== game exited status=$status, killing wine prefix ===" >> "$log" 2>&1 || true
kill_wine_prefix
echo "=== wine prefix killed, session ending ===" >> "$log" 2>&1 || true
exit $status
