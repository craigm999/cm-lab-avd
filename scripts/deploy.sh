#!/usr/bin/env bash
# Deploys the AVD environment at subscription scope.
#
# Usage:
#   export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'
#   ./scripts/deploy.sh <param-file> [what-if] [extra az args...]
#
# Examples:
#   ./scripts/deploy.sh infra/params/prod.bicepparam what-if
#   ./scripts/deploy.sh infra/params/prod.bicepparam
#
# The target subscription is read from the "// subscriptionId: <id>" header that
# scripts/New-AvdParameterFile.ps1 writes, or from $AVD_SUBSCRIPTION_ID.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARAM_FILE="${1:-$REPO_ROOT/infra/main.bicepparam}"
MODE="${2:-create}"
shift $(( $# > 2 ? 2 : $# ))
EXTRA_ARGS=("$@")

[[ -f "$PARAM_FILE" ]] || { echo "Parameter file not found: $PARAM_FILE" >&2; exit 1; }
: "${AVD_LOCAL_ADMIN_PASSWORD:?Set AVD_LOCAL_ADMIN_PASSWORD}"

SUBSCRIPTION_ID="${AVD_SUBSCRIPTION_ID:-$(sed -nE 's#^// *subscriptionId: *([0-9a-fA-F-]{36}).*#\1#p' "$PARAM_FILE" | head -1)}"
LOCATION="$(sed -nE "s#^param location = '([^']+)'.*#\1#p" "$PARAM_FILE" | head -1)"
LOCATION="${LOCATION:-uksouth}"

if [[ -n "$SUBSCRIPTION_ID" ]]; then
  az account set --subscription "$SUBSCRIPTION_ID"
fi
echo "Subscription: $(az account show --query '[name, id]' -o tsv | paste -sd ' ')"
echo "Region:       $LOCATION"
echo "Parameters:   $PARAM_FILE"

for rp in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.OperationalInsights Microsoft.Insights; do
  az provider register --namespace "$rp" --output none
done

DEPLOYMENT_NAME="avd-$(date +%Y%m%d%H%M%S)"
case "$MODE" in
  what-if)
    az deployment sub what-if --name "$DEPLOYMENT_NAME" --location "$LOCATION" \
      --template-file "$REPO_ROOT/infra/main.bicep" --parameters "$PARAM_FILE" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  create)
    az deployment sub create --name "$DEPLOYMENT_NAME" --location "$LOCATION" \
      --template-file "$REPO_ROOT/infra/main.bicep" --parameters "$PARAM_FILE" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
    ;;
  *)
    echo "Unknown mode '$MODE' (use what-if or create)" >&2; exit 1
    ;;
esac
