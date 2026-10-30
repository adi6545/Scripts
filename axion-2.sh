#!/usr/bin/env bash
# Axion fogos - every change we made, in one pass.
#
#   1. Twelve removed from common_mobile_full.mk
#   2. PixelPlayer added
#   3. FogosParts cloned + wired (bypass charging)
#   4. Picture Control disabled
#   5. AxDragoniteBoost disabled (guard in dispatchSceneCommands)
#   6. GlassBlur enabled (Axion's SD695 blur filter, from ax-dragonite-dev)
#   7. AxDiagnostics thermal warnings patched (156 C bug + 60->90 C threshold)
#   8. Build
#
# Idempotent - safe to re-run. Run from the ROM tree root:  bash axion-fogos-all.sh
set -euo pipefail

VARIANT="${VARIANT:-user}"
DEV=device/motorola/fogos
SDKFILE=axion_sdk/ax_dragonite/ax_dragonite_server/src/com/android/server/axdragonite/AxDragoniteImpl.kt
AXD=packages/apps/AxDiagnostics/src/com/axion/diagnostics/data
FWN=frameworks/native

[ -d .repo ]        || { echo "ERROR: no .repo here. Run from the ROM tree root."; exit 1; }
[ -d "$DEV" ]       || { echo "ERROR: $DEV missing - device tree not synced."; exit 1; }
[ -d "$FWN/.git" ]  || { echo "ERROR: $FWN missing - sync incomplete."; exit 1; }

# ---- 0. signing keys --------------------------------------------------
# The container is ephemeral, so the keys must arrive one of these ways.
# Order: already present -> local archive -> KEYS_URL -> generate -> testkey.
KEYOK=0
if [ -d vendor/lineage-priv/keys ]; then
  KEYOK=1
elif [ -f "$HOME/axion-keys.tar.gz" ]; then
  echo "keys: restoring from $HOME/axion-keys.tar.gz"
  mkdir -p vendor/lineage-priv
  tar xzf "$HOME/axion-keys.tar.gz" -C vendor/lineage-priv 2>/dev/null \
    || tar xzf "$HOME/axion-keys.tar.gz" -C .
  if [ -d vendor/lineage-priv/keys ]; then KEYOK=1; fi
elif [ -n "${KEYS_URL:-}" ] && [ -n "${KEYS_PASS:-}" ]; then
  echo "keys: fetching $KEYS_URL"
  mkdir -p vendor/lineage-priv
  curl -fsSL -o /tmp/k.enc "$KEYS_URL" || { echo "ERROR: KEYS_URL download failed"; exit 1; }
  openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:$KEYS_PASS" -in /tmp/k.enc \
    | tar xz -C vendor/lineage-priv
  rm -f /tmp/k.enc
  if [ -d vendor/lineage-priv/keys ]; then KEYOK=1; fi
elif [ "${ALLOW_NEW_KEYS:-0}" = "1" ]; then
  echo "keys: ALLOW_NEW_KEYS=1 - generating a NEW identity (will not match any previous build)"
  mkdir -p vendor/lineage-priv/keys
  for k in releasekey platform shared media networkstack sdk_sandbox bluetooth; do
    openssl genrsa -3 -out "vendor/lineage-priv/keys/$k.pem" 2048 2>/dev/null
    openssl req -new -x509 -key "vendor/lineage-priv/keys/$k.pem" \
      -out "vendor/lineage-priv/keys/$k.x509.pem" -days 10000 \
      -subj "/C=IN/O=Aditya/OU=Fogos/CN=Aditya Singh" 2>/dev/null
    openssl pkcs8 -in "vendor/lineage-priv/keys/$k.pem" -topk8 -outform DER \
      -out "vendor/lineage-priv/keys/$k.pk8" -nocrypt 2>/dev/null
  done
  # mainline certs Android expects in the same directory
  for f in build/make/target/product/security/*.pk8 build/make/target/product/security/*.x509.pem; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ -e "vendor/lineage-priv/keys/$b" ] || cp "$f" "vendor/lineage-priv/keys/$b"
  done
  KEYOK=1
fi

if [ "$KEYOK" = "0" ]; then
  echo "###############################################################"
  echo "#  NO SIGNING KEYS - building with AOSP testkey               #"
  echo "#  The zip will flash, but its identity is not yours and no   #"
  echo "#  future OTA can update a device running this build.         #"
  echo "#  Provide one of: vendor/lineage-priv/keys, ~/axion-keys.tar.gz,"
  echo "#  KEYS_URL+KEYS_PASS, or ALLOW_NEW_KEYS=1                    #"
  echo "###############################################################"
fi

# append a line, guaranteeing a trailing newline first (device.mk has none)
append_line() {
  local f=$1 line=$2
  [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"
  printf '%s\n' "$line" >> "$f"
}

# ---- 1. Twelve -------------------------------------------------------
echo "=== 1. Twelve ==="
P=vendor/lineage/config/common_mobile_full.mk
if [ -f "$P" ]; then
  python3 - "$P" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
n=re.sub(r"[ \t]*\\\r?\n[ \t]*Twelve[ \t]*\r?\n","\n",s)
n=re.sub(r"^[ \t]*Twelve[ \t]*\r?\n","",n,flags=re.M)
if n!=s: open(p,"w").write(n); print("  removed")
else: print("  not present")
PY
else echo "  $P not found"; fi

# ---- 2. PixelPlayer --------------------------------------------------
echo "=== 2. PixelPlayer ==="
mkdir -p vendor/pixelplayer/PixelPlayer
[ -f vendor/pixelplayer/PixelPlayer/PixelPlayer.apk ] || \
  curl -fsSL -o vendor/pixelplayer/PixelPlayer/PixelPlayer.apk \
    https://github.com/PixelPlayerHQ/PixelPlayer/releases/download/0.7.5-beta/PixelPlayer-arm64-v8a.apk
printf 'android_app_import {\n    name: "PixelPlayer",\n    apk: "PixelPlayer.apk",\n    presigned: true,\n    preprocessed: true,\n    dex_preopt: {\n        enabled: false,\n    },\n    product_specific: true,\n}\n' > vendor/pixelplayer/PixelPlayer/Android.bp
grep -qxF 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" || \
  append_line "$DEV/device.mk" 'PRODUCT_PACKAGES += PixelPlayer'
echo "  wired"

# ---- 3. FogosParts (bypass charging) ---------------------------------
echo "=== 3. FogosParts ==="
if [ -d packages/apps/FogosParts ]; then echo "  already present"
else
  git clone --depth=1 -q -b main \
    https://github.com/tiraq-official/android_packages_apps_FogosParts.git \
    packages/apps/FogosParts </dev/null
  echo "  cloned"
fi
grep -qxF 'include packages/apps/FogosParts/parts.mk' "$DEV/device.mk" || \
  append_line "$DEV/device.mk" 'include packages/apps/FogosParts/parts.mk'

# parts.mk appends to BOARD_VENDOR_SEPOLICY_DIRS, but device.mk is parsed long
# after BoardConfig.mk, so that line never takes effect. Set it here instead -
# without this the app cannot write the charging sysfs node.
if grep -q 'FogosParts/sepolicy' "$DEV/BoardConfig.mk" 2>/dev/null; then
  echo "  sepolicy already in BoardConfig.mk"
else
  append_line "$DEV/BoardConfig.mk" 'BOARD_VENDOR_SEPOLICY_DIRS += packages/apps/FogosParts/sepolicy/vendor'
  echo "  sepolicy added to BoardConfig.mk"
fi
echo "  wired"

# ---- 4. Picture Control ----------------------------------------------
echo "=== 4. Picture Control ==="
M=packages/apps/FogosParts/AndroidManifest.xml
if [ -f "$M" ]; then
  N=$(grep -c 'android:enabled="false"' "$M" || true)
  if [ "$N" = "0" ]; then
    sed -i 's#android:name=".display.PictureControlActivity"#android:name=".display.PictureControlActivity"\n            android:enabled="false"#' "$M"
    echo "  disabled"
  elif [ "$N" = "1" ]; then echo "  already disabled"
  else sed -i '0,/android:enabled="false"/!{/android:enabled="false"/d}' "$M"; echo "  duplicates removed"; fi
else echo "  manifest not found"; fi

# ---- 5. Dragonite off ------------------------------------------------
echo "=== 5. AxDragoniteBoost ==="
if [ -f "$SDKFILE" ]; then
  git -C axion_sdk rev-parse --git-dir >/dev/null 2>&1 && \
    git -C axion_sdk checkout -- \
      ax_dragonite/ax_dragonite_server/src/com/android/server/axdragonite/AxDragoniteImpl.kt || true
  python3 - "$SDKFILE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
if "BOOST_DISABLED_FOR_DEVICE" in s:
    print("  already disabled"); raise SystemExit
a = "    fun dispatchSceneCommands(sceneId: Int, bundle: Bundle?) {\n"
if a not in s:
    print("  ANCHOR NOT FOUND - patch by hand"); raise SystemExit(1)
ins = ("    // Boost disabled on this device: a working boost pins the CPU and\n"
       "    // confines SF/RenderEngine to 4 of 8 cores here, which measures worse\n"
       "    // than leaving it off. Handles are still allocated and released.\n"
       "    private val BOOST_DISABLED_FOR_DEVICE = true\n\n"
       + a + "        if (BOOST_DISABLED_FOR_DEVICE) return\n")
open(p,"w").write(s.replace(a, ins, 1)); print("  disabled")
PY
else echo "  $SDKFILE not found - is axion_sdk synced?"; fi

# ---- 6. GlassBlur ----------------------------------------------------
echo "=== 6. GlassBlur ==="
if [ -f "$FWN/libs/renderengine/skia/filters/GlassBlurFilter.cpp" ] && \
   grep -q "GlassBlurFilter.cpp" "$FWN/libs/renderengine/Android.bp" 2>/dev/null && \
   grep -q "new GlassBlurFilter" "$FWN/libs/renderengine/skia/SkiaRenderEngine.cpp" 2>/dev/null; then
  echo "  already present"
else
  if [ -n "$(git -C "$FWN" status --porcelain 2>/dev/null)" ]; then
    echo "  ERROR: $FWN has uncommitted changes:"; git -C "$FWN" status --short | head -8 | sed 's/^/    /'; exit 1
  fi
  git -C "$FWN" fetch --depth=400 https://github.com/AxionAOSP/android_frameworks_native.git ax-dragonite-dev 2>&1 | tail -1
  for c in 06ae3c3645 ea0184011c; do
    git -C "$FWN" cat-file -e "${c}^{commit}" 2>/dev/null || { echo "  ERROR: $c not fetched"; exit 1; }
  done
  git -C "$FWN" -c user.email=local@local -c user.name=local cherry-pick 06ae3c3645 ea0184011c
fi

# ---- 7. AxDiagnostics thermal ----------------------------------------
echo "=== 7. AxDiagnostics thermal ==="
TI=$AXD/ThermalInfo.kt
HA=$AXD/HealthAnalyzer.kt
if [ -f "$TI" ]; then
  python3 - "$TI" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
if "return@forEach" in s: print("  ThermalInfo: already filtered"); raise SystemExit
anchor="val tempC = if (kotlin.math.abs(temp) > 200L) temp / 1000f else temp.toFloat()"
if anchor not in s: print("  ThermalInfo: ANCHOR NOT FOUND"); raise SystemExit
add = anchor + """
                // Some zones report a raw ADC value rather than a temperature:
                // 156000 passes the >200 millidegree heuristic and becomes 156 C,
                // which wins maxByOrNull and raises a bogus "Thermal emergency".
                if (tempC < 0f || tempC > 125f) return@forEach"""
open(p,"w").write(s.replace(anchor, add, 1)); print("  ThermalInfo: filter added")
PY
else echo "  ThermalInfo not found"; fi
if [ -f "$HA" ]; then
  python3 - "$HA" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
if "maxTemperature > 90f" in s: print("  HealthAnalyzer: already raised"); raise SystemExit
if "maxTemperature > 60f" not in s: print("  HealthAnalyzer: ANCHOR NOT FOUND"); raise SystemExit
open(p,"w").write(s.replace("maxTemperature > 60f", "maxTemperature > 90f", 1))
print("  HealthAnalyzer: 60 -> 90 C")
PY
else echo "  HealthAnalyzer not found"; fi

# ---- 8. verify -------------------------------------------------------
echo "=== VERIFY ==="
fail=0
c() { if [ "$2" = "$3" ]; then printf '  PASS  %-34s %s\n' "$1" "$2"
      else printf '  FAIL  %-34s got %s want %s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
c "Twelve removed"            "$(grep -c Twelve vendor/lineage/config/common_mobile_full.mk 2>/dev/null || true)" 0
c "no dangling backslash"     "$(grep -B1 '^endif' vendor/lineage/config/common_mobile_full.mk 2>/dev/null | grep -c '\\$' || true)" 0
c "PixelPlayer APK"           "$(test -f vendor/pixelplayer/PixelPlayer/PixelPlayer.apk && echo 1 || echo 0)" 1
c "PixelPlayer in device.mk"  "$(grep -c 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" 2>/dev/null || true)" 1
c "parts.mk referenced"       "$(grep -c 'FogosParts/parts.mk' "$DEV/device.mk" 2>/dev/null || true)" 1
c "PicCtrl disabled"          "$(grep -A1 'PictureControlActivity' "$M" 2>/dev/null | grep -c 'android:enabled="false"' || true)" 1
c "PicCtrl not duplicated"    "$(grep -c 'android:enabled="false"' "$M" 2>/dev/null || true)" 1
c "dragonite guard present"   "$(grep -c 'BOOST_DISABLED_FOR_DEVICE' "$SDKFILE" 2>/dev/null || true)" 2
c "dispatchSceneCommands ok"  "$(grep -c 'fun dispatchSceneCommands(sceneId: Int, bundle: Bundle?)' "$SDKFILE" 2>/dev/null || true)" 1
c "GlassBlurFilter.cpp"       "$(test -f "$FWN/libs/renderengine/skia/filters/GlassBlurFilter.cpp" && echo 1 || echo 0)" 1
c "GlassBlur in Android.bp"   "$(grep -c 'skia/filters/GlassBlurFilter.cpp' "$FWN/libs/renderengine/Android.bp" 2>/dev/null || true)" 1
c "switch uses GlassBlur"     "$(grep -c 'new GlassBlurFilter' "$FWN/libs/renderengine/skia/SkiaRenderEngine.cpp" 2>/dev/null || true)" 1
c "old Kawase refs gone"      "$(grep -c 'new KawaseBlur' "$FWN/libs/renderengine/skia/SkiaRenderEngine.cpp" 2>/dev/null || true)" 0
c "thermal filter added"      "$(grep -c 'tempC < 0f || tempC > 125f' "$TI" 2>/dev/null || true)" 1
c "thermal threshold 90"      "$(grep -c 'maxTemperature > 90f' "$HA" 2>/dev/null || true)" 1
c "FogosParts sepolicy in BoardConfig" "$(grep -c 'FogosParts/sepolicy' "$DEV/BoardConfig.mk" 2>/dev/null || echo 0)" 1
c "keys present"              "$(test -d vendor/lineage-priv/keys && echo 1 || echo 0)" "${KEYOK:-1}"
echo
if [ "$fail" != "0" ]; then echo "ABORTING: $fail check(s) failed"; exit 1; fi
echo "all checks passed"

# ---- 9. build --------------------------------------------------------
echo "=== BUILD $(date -u) ==="
export ANDROID_BUILD_TOP="$(pwd)"
export ANDROID_KEY_PATH="$ANDROID_BUILD_TOP/vendor/lineage-priv/keys"
set +u
source build/envsetup.sh
make installclean
axion fogos "$VARIANT" core
ax -br
echo "=== BUILD DONE $(date -u) ==="
