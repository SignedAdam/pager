#!/bin/bash
# Sign a locally built pager with a stable identity, if this Mac has one.
#
# macOS remembers permissions (Accessibility, for ambient's middle-click) per
# code signature. An ad-hoc signature changes with every build, so each rebuild
# silently loses the grant. Signed with the same certificate every time, the
# grant survives. Nothing happens on a Mac without the identity (CI, other
# people); `make signing` creates one, once.
#
#   tools/local-sign.sh <binary>     sign if "Pager Local Signing" exists
#   tools/local-sign.sh --setup      create it in the login keychain
set -euo pipefail
NAME="Pager Local Signing"
ID="com.signedadam.pager"

identity() { security find-identity -p codesigning 2>/dev/null | grep "\"$NAME\"" | head -1 | awk '{print $2}'; }

if [ "${1:-}" = "--setup" ]; then
  if [ -n "$(identity)" ]; then echo "  already set up: $NAME"; exit 0; fi
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$NAME" > "$tmp/cnf"
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cnf" -keyout "$tmp/key" -out "$tmp/crt" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key" -in "$tmp/crt" -name "$NAME" -passout pass:pager -out "$tmp/p12" 2>/dev/null
  security import "$tmp/p12" -k "$HOME/Library/Keychains/login.keychain-db" -P pager -T /usr/bin/codesign >/dev/null
  echo "  created $NAME. Rebuild, allow pager in Accessibility once more, and rebuilds keep the grant."
  exit 0
fi

bin="${1:?usage: local-sign.sh <binary> | --setup}"
hash="$(identity)"
[ -n "$hash" ] || exit 0
codesign -f -s "$hash" -i "$ID" "$bin" 2>/dev/null || echo "  (could not sign $bin with $NAME; it stays ad-hoc)"
