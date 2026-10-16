#!/bin/bash
# Use the shared signing backup for releases. Never create a separate release key.
set -euo pipefail

NAME="Gilad Peleg Local Signing"
REPO=${REPO:-pgilad/Maccy}
ENVIRONMENT=release
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "Usage: scripts/configure-release-signing.sh /path/to/gilad-peleg-local-signing.p12" >&2
  exit 1
fi

# Compare the public certificates before changing GitHub secrets.
LOCAL_CERTIFICATE=$(security find-certificate -c "$NAME" -p "$KEYCHAIN" |
  /usr/bin/openssl x509 -noout -fingerprint -sha256)
IFS= read -r -s -p "Signing backup password: " PASSWORD
printf '\n'
BACKUP_CERTIFICATE=$(/usr/bin/openssl pkcs12 -in "$1" -clcerts -nokeys -passin fd:3 \
  3<<< "$PASSWORD" | /usr/bin/openssl x509 -noout -fingerprint -sha256)
if [ "$BACKUP_CERTIFICATE" != "$LOCAL_CERTIFICATE" ]; then
  echo "error: the backup does not match the shared signing certificate in the login Keychain." >&2
  exit 1
fi

# Check that the backup also holds a private key, without writing it to disk.
/usr/bin/openssl pkcs12 -in "$1" -nocerts -nodes -passin fd:3 \
  3<<< "$PASSWORD" | /usr/bin/openssl pkey -noout

echo "Limiting the release environment to version tags…"
gh api --method PUT "repos/$REPO/environments/$ENVIRONMENT" --silent --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
if [ -z "$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.name == "v*" and .type == "tag") | .id')" ]; then
  gh api --method POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    --silent -f name='v*' -f type=tag
fi

echo "Storing the shared identity in the release environment secrets…"
base64 < "$1" | gh secret set MACCY_SIGNING_P12 --repo "$REPO" --env "$ENVIRONMENT"
printf '%s' "$PASSWORD" | gh secret set MACCY_SIGNING_P12_PASSWORD --repo "$REPO" --env "$ENVIRONMENT"
unset PASSWORD
echo "Release signing uses the shared local identity."
