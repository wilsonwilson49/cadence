#!/bin/bash
# Last build step of the Mac app (project.yml): signs it with the permanent local certificate from
# scripts/make-signing-identity.sh, so macOS permissions (Accessibility, Automation) survive rebuilds.
# Falls back to ad hoc signing when that certificate isn't on this Mac.
set -uo pipefail
APP="${1:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
KC="$HOME/Library/Keychains/cadence-signing.keychain-db"
PWFILE="$HOME/Library/Application Support/CadenceSigning/keychain-password"
if [ -f "$KC" ] && [ -f "$PWFILE" ]; then
  security unlock-keychain -p "$(cat "$PWFILE")" "$KC" 2>/dev/null
  HASH=$(security find-certificate -c "Cadence Local Signing" -Z "$KC" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')
  # codesign only finds identities in the keychain search list, so the keychain joins it just for this step.
  OLD_LIST=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')
  restore() { local IFS=$'\n'; # shellcheck disable=SC2086
    security list-keychains -d user -s $OLD_LIST; }
  trap restore EXIT
  (IFS=$'\n'; # shellcheck disable=SC2086
   security list-keychains -d user -s $OLD_LIST "$KC")
  if [ -n "$HASH" ] && /usr/bin/codesign --force --sign "$HASH" --timestamp=none "$APP"; then
    echo "Signed with Cadence Local Signing"; exit 0
  fi
  echo "warning: signing with Cadence Local Signing failed; signing ad hoc instead"
fi
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
