#!/usr/bin/env bash
# fogos CI setup - writes the three ci/ scripts into the device tree, commits
# and pushes them, then prints the one-line Crave command.
#
#   cd ~/pos && bash setup-fogos-ci.sh
#
# Run it from the ROM tree root. After it pushes, this works from anywhere:
#   crave run --no-patch -- "curl -fsSL https://raw.githubusercontent.com/adi6545/android_device_motorola_fogos/pixel-16/ci/run.sh | bash"
set -euo pipefail

DEV=device/motorola/fogos
OWNER=adi6545
REPO=android_device_motorola_fogos
BRANCH=pixel-16

if [ ! -d "$DEV" ]; then
  echo "ERROR: $DEV not found. Run this from the ROM tree root (e.g. ~/pos)."
  exit 1
fi
mkdir -p "$DEV/ci"

# ---- ci/run.sh ---------------------------------------------------------
cat > "$DEV/ci/run.sh" <<'RUNEOF'
#!/usr/bin/env bash
# fogos full pipeline: sync then build.
#   curl -fsSL https://raw.githubusercontent.com/adi6545/android_device_motorola_fogos/pixel-16/ci/run.sh | bash
set -euo pipefail

BASE="https://raw.githubusercontent.com/adi6545/android_device_motorola_fogos/pixel-16/ci"

echo "=== FOGOS PIPELINE START $(date -u) ==="
curl -fsSL "$BASE/sync.sh"  | bash
curl -fsSL "$BASE/build.sh" | bash
echo "=== FOGOS PIPELINE DONE $(date -u) ==="
RUNEOF

# ---- ci/sync.sh --------------------------------------------------------
cat > "$DEV/ci/sync.sh" <<'SYNCEOF'
#!/usr/bin/env bash
# fogos: repo init + sync + the device trees.
# Safe to pipe: every git call gets </dev/null so it cannot eat the script.
set -euo pipefail

# ---- what to build -----------------------------------------------------
ROM=pixelos            # pixelos | axion | lunaris
BRANCH=sixteen-qpr2    # branch of that ROM's manifest

case "$ROM" in
  pixelos) URL=https://github.com/PixelOS-AOSP/android_manifest.git ;;
  axion)   URL=https://github.com/AxionAOSP/android.git ;;
  lunaris) URL=https://github.com/Lunaris-AOSP/android.git ;;
  *) echo "ERROR: unknown ROM '$ROM'"; exit 1 ;;
esac

echo "=== SYNC START  rom=$ROM branch=$BRANCH $(date -u) ==="
repo init --depth=1 -u "$URL" -b "$BRANCH" --git-lfs
repo sync -j8 --depth=1 --force-sync --no-tags --no-clone-bundle

# ---- device trees ------------------------------------------------------
# --depth=1 everywhere; </dev/null so a piped run is not disturbed.
clone() {   # clone <branch> <path> <url>
  [ -d "$2" ] && rm -rf "$2"
  git clone --depth=1 -q -b "$1" "$3" "$2" </dev/null
  echo "  cloned $2 @$1"
}

clone axion          vendor/motorola/fogos      https://github.com/adi6545/proprietary_vendor_motorola_fogos.git
clone pixel-16       device/motorola/fogos      https://github.com/adi6545/android_device_motorola_fogos.git
clone axion          kernel/motorola/sm6375     https://github.com/adi6545/android_kernel_motorola_sm6375.git
clone sixteen-qpr2   vendor/motorola/motocamera https://github.com/adi6545/vendor_motorola_motocamera.git
clone lineage-23.2   hardware/motorola          https://github.com/adi6545/android_hardware_motorola.git
clone lineage-23.2   hardware/samsung_slsi/nfc  https://github.com/adi6545/android_hardware_samsung_slsi_nfc.git
clone lineage-23.2   packages/apps/DolbyAtmos   https://github.com/adi6545/android_packages_apps_DolbyAtmos.git
clone sixteen-qpr2   vendor/custom              https://github.com/adi6545/android_vendor_custom.git

echo "=== SYNC DONE $(date -u) ==="
SYNCEOF

# ---- ci/build.sh -------------------------------------------------------
cat > "$DEV/ci/build.sh" <<'BUILDEOF'
#!/usr/bin/env bash
# fogos: apply the customisations, verify them, then build.
set -euo pipefail

ROM=pixelos                 # pixelos | axion | lunaris
DEV=device/motorola/fogos

echo "=== CUSTOMISE $(date -u) ==="

# 1. Twelve --------------------------------------------------------------
# LAST item of a backslash list: deleting its line alone leaves the previous
# item with a dangling backslash that eats the next `endif`.
P=vendor/lineage/config/common_mobile_full.mk
if [ -f "$P" ]; then
  python3 -c 'import re,sys;p=sys.argv[1];s=open(p).read();n=re.sub(r"[ \t]*\\\r?\n[ \t]*Twelve[ \t]*\r?\n","\n",s);n=re.sub(r"^[ \t]*Twelve[ \t]*\r?\n","",n,flags=re.M);open(p,"w").write(n);print("  Twelve:","removed" if n!=s else "not present")' "$P"
else
  echo "  Twelve: $P not found"
fi

# 2. Chocola (only exists on ROMs with vendor/prebuilts) -----------------
if [ -f vendor/prebuilts/prebuilts.mk ]; then
  sed -i '/Chocola/d' vendor/prebuilts/prebuilts.mk && echo "  Chocola: removed"
else
  echo "  Chocola: skipped (no vendor/prebuilts)"
fi

# 3. PixelPlayer ---------------------------------------------------------
mkdir -p vendor/pixelplayer/PixelPlayer
[ -f vendor/pixelplayer/PixelPlayer/PixelPlayer.apk ] || \
  curl -fsSL -o vendor/pixelplayer/PixelPlayer/PixelPlayer.apk \
    https://github.com/PixelPlayerHQ/PixelPlayer/releases/download/0.7.5-beta/PixelPlayer-arm64-v8a.apk
printf 'android_app_import {\n    name: "PixelPlayer",\n    apk: "PixelPlayer.apk",\n    presigned: true,\n    preprocessed: true,\n    dex_preopt: {\n        enabled: false,\n    },\n    product_specific: true,\n}\n' > vendor/pixelplayer/PixelPlayer/Android.bp
grep -qxF 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" || \
  echo 'PRODUCT_PACKAGES += PixelPlayer' >> "$DEV/device.mk"
echo "  PixelPlayer: wired"

# 4. Bypass charging (FogosParts) ---------------------------------------
# parts.mk is what provides it. Match EITHER form so a second copy is never
# added - a duplicate BOARD_VENDOR_SEPOLICY_DIRS entry breaks the build.
[ -d packages/apps/FogosParts ] || \
  git clone --depth=1 -q -b main \
    https://github.com/tiraq-official/android_packages_apps_FogosParts.git \
    packages/apps/FogosParts </dev/null
grep -q 'FogosParts/parts.mk' "$DEV/device.mk" || \
  echo 'include packages/apps/FogosParts/parts.mk' >> "$DEV/device.mk"
echo "  FogosParts: wired (bypass charging)"

# 5. Picture Control ----------------------------------------------------
M=packages/apps/FogosParts/AndroidManifest.xml
if [ -f "$M" ]; then
  N=$(grep -c 'android:enabled="false"' "$M" || true)
  if [ "$N" = "0" ]; then
    sed -i 's#android:name=".display.PictureControlActivity"#android:name=".display.PictureControlActivity"\n            android:enabled="false"#' "$M"
    echo "  PicCtrl: disabled"
  elif [ "$N" = "1" ]; then
    echo "  PicCtrl: already disabled"
  else
    sed -i '0,/android:enabled="false"/!{/android:enabled="false"/d}' "$M"
    echo "  PicCtrl: removed duplicates (was $N)"
  fi
fi

# 6. FogosParts KCAL fix ------------------------------------------------
# reduceToKernel() used (VAL_KMAX - ADJ_KDEFAULT); both are 255, so the
# multiplier was 0 and kcal_val/kcal_cont always wrote 255 - the sliders did
# nothing. Use the real span (ADJ_KDEFAULT - SAT_KMIN) = 127.
KCAL=packages/apps/FogosParts/src/org/lineageos/fogosparts/display/KcalUtils.kt
if [ -f "$KCAL" ]; then
  if grep -q 'ui \* (VAL_KMAX - ADJ_KDEFAULT)' "$KCAL"; then
    sed -i 's/ui \* (VAL_KMAX - ADJ_KDEFAULT)/ui * (ADJ_KDEFAULT - SAT_KMIN)/' "$KCAL"
    echo "  KCAL: fixed (sliders were no-ops)"
  else
    echo "  KCAL: already fixed or upstream changed"
  fi
fi

# ---- verify before spending build time --------------------------------
echo "=== VERIFY $(date -u) ==="
fail=0
c() {   # c "label" actual want
  if [ "$2" = "$3" ]; then
    printf '  PASS  %-34s %s\n' "$1" "$2"
  else
    printf '  FAIL  %-34s got %s, want %s\n' "$1" "$2" "$3"; fail=$((fail + 1))
  fi
}
c "Twelve removed"          "$(grep -c Twelve vendor/lineage/config/common_mobile_full.mk 2>/dev/null || true)" 0
c "no dangling backslash"   "$(grep -B1 '^endif' vendor/lineage/config/common_mobile_full.mk 2>/dev/null | grep -c '\\$' || true)" 0
c "PixelPlayer APK"         "$(test -f vendor/pixelplayer/PixelPlayer/PixelPlayer.apk && echo 1 || echo 0)" 1
c "PixelPlayer in device.mk" "$(grep -c 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk" 2>/dev/null || true)" 1
c "parts.mk exists"         "$(test -f packages/apps/FogosParts/parts.mk && echo 1 || echo 0)" 1
c "parts.mk referenced"     "$(grep -c 'FogosParts/parts.mk' "$DEV/device.mk" 2>/dev/null || true)" 1
c "PicCtrl disabled"        "$(grep -A1 'PictureControlActivity' "$M" 2>/dev/null | grep -c 'android:enabled="false"' || true)" 1
c "PicCtrl not duplicated"  "$(grep -c 'android:enabled="false"' "$M" 2>/dev/null || true)" 1
c "KCAL fix applied"        "$(grep -c 'ui \* (ADJ_KDEFAULT - SAT_KMIN)' "$KCAL" 2>/dev/null || true)" 1
c "KCAL bug gone"           "$(grep -c 'ui \* (VAL_KMAX - ADJ_KDEFAULT)' "$KCAL" 2>/dev/null || true)" 0

if [ "$fail" != "0" ]; then
  echo "ABORTING: $fail check(s) failed - not starting a multi-hour build."
  exit 1
fi
echo "all checks passed"

# ---- build -------------------------------------------------------------
echo "=== BUILD $(date -u) ==="
source build/envsetup.sh
case "$ROM" in
  pixelos)
    lunch custom_fogos-bp4a-userdebug
    m pixelos
    ;;
  *) echo "ERROR: unknown ROM '$ROM'"; exit 1 ;;
esac
echo "=== BUILD DONE $(date -u) ==="
BUILDEOF

chmod +x "$DEV"/ci/*.sh
echo "wrote:"
ls -l "$DEV/ci"
