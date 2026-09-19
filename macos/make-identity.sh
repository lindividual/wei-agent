#!/usr/bin/env bash
#
# Make the self-signed code-signing identity that `make-app.sh` signs with.
#
#     macos/make-identity.sh [name]        (default: wei-dev)
#
# ## Why an identity at all
#
# macOS decides "is this the same app as last time?" from the app's *designated requirement*, and a
# permission (TCC) is granted to that requirement. What goes into it depends on how the app was
# signed:
#
#     ad-hoc:  designated => identifier "…" and cdhash H"…"
#     signed:  designated => identifier "…" and certificate root = H"…"
#
# The cdhash is a hash of the build. It changes with every build, so under ad-hoc signing **every
# rebuild is a different app** to macOS and the reader is asked for the permission again — measured,
# and written up in `docs/macos-pitfalls.md`. A certificate does not change, so a requirement built
# from one does not either: two builds signed with one identity have different cdhashes and a
# byte-identical requirement.
#
# ## What this is not
#
# Not a Developer ID. It is trusted by this machine only, which is exactly what a permission granted
# to the app on this machine needs. Signing with it does not make a downloaded copy openable — that
# still wants a Developer ID and notarization, and `make-app.sh` says so when it finishes.
#
# ## Undo
#
#     security delete-identity -c "<name>" -t
#
# `-t` is what removes the trust setting too; without it the certificate goes and the trust setting
# stays, pointing at nothing.

set -euo pipefail

NAME="${1:-wei-dev}"
# The login keychain rather than a file in the repository, and the user's trust settings rather than
# the system's: both keep this to the account that ran it and need no administrator, which is the
# point of a certificate for one machine.
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# What `codesign` will read back. `find-identity` prints the name in quotes, which is what makes the
# match unambiguous — a substring match would also find `wei-dev-2`.
installed() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; }
present() { security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; }

WORK="$(mktemp -d)"
# The private key lives only here, and this removes it on every exit — including a failure part-way
# through. Nothing in this repository should ever hold a key.
trap 'rm -rf "$WORK"' EXIT

# An identity that exists but is not trusted yet has to be *finished*, not duplicated: two
# certificates sharing one name is a name that selects neither.
if present && ! installed; then
  echo "identity '$NAME' is installed but not trusted — adding the trust setting."
  security find-certificate -c "$NAME" -p >"$WORK/cert.pem"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"
  installed || {
    echo "still not valid after adding trust; giving up" >&2
    exit 1
  }
  echo "done."
  exit 0
fi

if installed; then
  echo "identity '$NAME' is already installed and valid — nothing to do."
  security find-identity -v -p codesigning | grep "\"$NAME\"" | sed 's/^ */  /'
  exit 0
fi

# `codeSigning` on the extended key usage is what lets `codesign` accept the certificate at all, and
# it has to be **critical** — the same marking Apple's own certificates carry. `basicConstraints`
# says this is a leaf and not a CA: it signs this app and nothing else.
cat >"$WORK/certs.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext

[ dn ]
CN = $NAME
O  = wei
C  = US

[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "==> generate (10 years)"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/certs.cnf" 2>/dev/null

# A password for the one hop through `pkcs12`, generated rather than chosen and never written
# anywhere that outlives this script. The key is unencrypted on disk for the seconds it takes to
# import, inside a directory only this user can read.
P12PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -name "$NAME" -passout "pass:$P12PW" 2>/dev/null

echo "==> import into the login keychain"
# `-T` marks the tools allowed to use the key without a prompt. Without it every signing run raises
# a keychain dialog — and a build script that is waiting on a dialog looks like a build script that
# hung, which is a worse failure than it sounds.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PW" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "==> trust it for code signing (this account only)"
# No `-d`, so this is the user's trust settings and not the system's: no administrator, and the
# removal above is complete.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if ! installed; then
  echo "the certificate imported but is still not valid; check 'security find-identity -v -p codesigning'" >&2
  exit 1
fi

echo
echo "done. 'macos/make-app.sh' will now sign with '$NAME'."
echo
echo "  remove it:  security delete-identity -c \"$NAME\" -t"
echo
echo "Note: a permission granted to an earlier ad-hoc build does not carry over to this one — the"
echo "first run after this change is asked for it once more, and every rebuild after that is not."
