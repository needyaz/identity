#!/usr/bin/env bash
# Print the adb serial of a running Android emulator or device, booting the first AVD headlessly when none is up.
# Override the AVD with AVD=<name>. Everything but the serial goes to stderr.
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
[ -d "$SDK" ] || SDK="$HOME/Library/Android/sdk"
ADB="$SDK/platform-tools/adb"
EMULATOR="$SDK/emulator/emulator"
serial() { "$ADB" devices 2>/dev/null | awk 'NR>1 && $2=="device" && !f {print $1; f=1}'; }
S="$(serial || true)"
if [ -z "$S" ]; then
  AVD="${AVD:-$("$EMULATOR" -list-avds 2>/dev/null | grep -vi screenshot | head -1)}"
  [ -n "$AVD" ] || { echo "no Android AVD found (set AVD)" >&2; exit 1; }
  echo "booting Android emulator '$AVD' (headless)" >&2
  nohup "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-boot-anim -no-snapshot >/dev/null 2>&1 &
  "$ADB" wait-for-device
  for _ in $(seq 1 150); do
    [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 2
  done
  [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] || { echo "emulator never finished booting" >&2; exit 1; }
  S="$(serial)"
fi
echo "$S"
