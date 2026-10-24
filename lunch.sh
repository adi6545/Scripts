crave run --no-patch -- "repo init --depth=1 -u https://github.com/PixelOS-AOSP/android_manifest.git -b sixteen-qpr2 --git-lfs &&
/opt/crave/resync.sh &&
rm -rf vendor/custom packages/apps/DolbyAtmos &&
git clone --depth=1 -b axion https://github.com/adi6545/proprietary_vendor_motorola_fogos.git vendor/motorola/fogos &&
git clone --depth=1 -b pixel-16 https://github.com/adi6545/android_device_motorola_fogos.git device/motorola/fogos &&
git clone --depth=1 -b axion https://github.com/adi6545/android_kernel_motorola_sm6375.git kernel/motorola/sm6375 &&
git clone --depth=1 -b sixteen-qpr2 https://github.com/adi6545/vendor_motorola_motocamera.git vendor/motorola/motocamera &&
git clone --depth=1 -b lineage-23.2 https://github.com/adi6545/android_hardware_motorola.git hardware/motorola &&
git clone --depth=1 -b lineage-23.2 https://github.com/adi6545/android_hardware_samsung_slsi_nfc.git hardware/samsung_slsi/nfc &&
git clone --depth=1 -b lineage-23.2 https://github.com/adi6545/android_packages_apps_DolbyAtmos.git packages/apps/DolbyAtmos &&
git clone --depth=1 -b sixteen-qpr2 https://github.com/adi6545/android_vendor_custom.git vendor/custom &&
cat > apply.sh <<'SCRIPT'
#!/usr/bin/env bash
set -e
DEV=device/motorola/fogos
P=vendor/lineage/config/common_mobile_full.mk
python3 -c 'import re,sys;p=sys.argv[1];s=open(p).read();n=re.sub(r"[ \t]*\\\r?\n[ \t]*Twelve[ \t]*\r?\n","\n",s);n=re.sub(r"^[ \t]*Twelve[ \t]*\r?\n","",n,flags=re.M);open(p,"w").write(n);print("Twelve:","removed" if n!=s else "not present")' "$P"
if [ -f vendor/prebuilts/prebuilts.mk ]; then sed -i '/Chocola/d' vendor/prebuilts/prebuilts.mk && echo "Chocola: removed"; else echo "Chocola: skipped (no vendor/prebuilts in this tree)"; fi
mkdir -p vendor/pixelplayer/PixelPlayer
[ -f vendor/pixelplayer/PixelPlayer/PixelPlayer.apk ]  curl -L --fail -o vendor/pixelplayer/PixelPlayer/PixelPlayer.apk https://github.com/PixelPlayerHQ/PixelPlayer/releases/download/0.7.5-beta/PixelPlayer-arm64-v8a.apk
printf 'android_app_import {\n    name: "PixelPlayer",\n    apk: "PixelPlayer.apk",\n    presigned: true,\n    preprocessed: true,\n    dex_preopt: {\n        enabled: false,\n    },\n    product_specific: true,\n}\n' > vendor/pixelplayer/PixelPlayer/Android.bp
grep -qxF 'PRODUCT_PACKAGES += PixelPlayer' "$DEV/device.mk"  echo 'PRODUCT_PACKAGES += PixelPlayer' >> "$DEV/device.mk"
echo "PixelPlayer: wired"
[ -d packages/apps/FogosParts ]  git clone --depth=1 -b main https://github.com/tiraq-official/android_packages_apps_FogosParts.git packages/apps/FogosParts
grep -q 'FogosParts/parts.mk' "$DEV/device.mk"  echo 'include packages/apps/FogosParts/parts.mk' >> "$DEV/device.mk"
echo "FogosParts: wired (bypass charging)"
M=packages/apps/FogosParts/AndroidManifest.xml
N=$(grep -c 'android:enabled="false"' "$M" || true)
if [ "$N" = "0" ]; then sed -i 's#android:name=".display.PictureControlActivity"#android:name=".display.PictureControlActivity"\n            android:enabled="false"#' "$M"; echo "PicCtrl: disabled"
elif [ "$N" = "1" ]; then echo "PicCtrl: already disabled"
else sed -i '0,/android:enabled="false"/!{/android:enabled="false"/d}' "$M"; echo "PicCtrl: removed duplicates (was $N)"; fi
echo "done. now:  make installclean && mka bacon"
SCRIPT
bash apply.sh &&
source build/envsetup.sh && lunch custom_fogos-bp4a-userdebug && m pixelos"