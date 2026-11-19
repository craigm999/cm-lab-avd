#!/usr/bin/env bash
# Deploys the AVD environment at subscription scope.
#
# Usage:
#   export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'
#   export AVD_USERS_GROUP_ID='<entra group object id>'
#   export AVD_ADMINS_GROUP_ID='<entra group object id>'   # optional
#   ./scripts/deploy.sh [what-if]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCATION="${LOCATION:-uksouth}"
DEPLOYMENT_NAME="avd-$(date +%Y%m%d%H%M%S)"

: "${AVD_LOCAL_ADMIN_PASSWORD:?Set AVD_LOCAL_ADMIN_PASSWORD}"
: "${AVD_USERS_GROUP_ID:?Set AVD_USERS_GROUP_ID}"

# Look up the Azure Virtual Desktop service principal (used by autoscale + Start VM on Connect).
if [[ -z "${AVD_SP_OBJECT_ID:-}" ]]; then
  AVD_SP_OBJECT_ID="$(az ad sp show --id 9cdead84-a844-4324-93f2-b2e6bb768d07 --query id -o tsv 2>/dev/null || true)"
  export AVD_SP_OBJECT_ID
  [[ -z "$AVD_SP_OBJECT_ID" ]] && echo "WARNING: AVD service principal not found - autoscale/Start VM on Connect role not assigned."
fi

# Resource providers
for rp in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights; do
  az provider register --namespace "$rp" --output none
done

if [[ "${1:-}" == "what-if" ]]; then
  az deployment sub what-if \
    --name "$DEPLOYMENT_NAME" \
    --location "$LOCATION" \
    --template-file "$REPO_ROOT/infra/main.bicep" \
    --parameters "$REPO_ROOT/infra/main.bicepparam"
else
  az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --location "$LOCATION" \
    --template-file "$REPO_ROOT/infra/main.bicep" \
    --parameters "$REPO_ROOT/infra/main.bicepparam"
fi
