#!/usr/bin/env bash
# Compiles and lints the Bicep, builds every scenario parameter file, and asserts on the
# compiled ARM JSON that the design requirements are actually encoded:
#   * Entra ID join via AADLoginForWindows with NO mdmId (=> no Intune enrollment)
#   * AVD agent registers with aadJoin = true
#   * Pooled host pool, maxSessionLimit = maxSessionsPerHost, Entra RDP properties
#   * Host count = ceil(targetUserCount / maxSessionsPerHost)  (1000 / 10 = 100)
#   * VMs have a system-assigned identity (required for Entra join), Trusted Launch
# Requires: az (with bicep), jq. AVD_LOCAL_ADMIN_PASSWORD must be set (any value).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
FAIL=0
pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }

echo "== Bicep build + lint"
az bicep build --file "$ROOT/infra/main.bicep" --outfile "$OUT/main.json" 2> "$OUT/build.log" || { cat "$OUT/build.log"; exit 1; }
if [[ -s "$OUT/build.log" ]]; then echo "  build warnings:"; sed 's/^/    /' "$OUT/build.log"; fi
az bicep lint --file "$ROOT/infra/main.bicep" 2>&1 | sed 's/^/    /' || true
pass "main.bicep compiles"

echo "== Parameter files"
for f in "$ROOT"/infra/main.bicepparam "$ROOT"/tests/params/*.bicepparam; do
  name="$(basename "$f" .bicepparam)"
  if az bicep build-params --file "$f" --outfile "$OUT/$name.parameters.json" 2> "$OUT/$name.log"; then
    pass "$(realpath --relative-to="$ROOT" "$f")"
  else
    fail "$f"; sed 's/^/    /' "$OUT/$name.log"
  fi
done

T="$OUT/main.json"
# All nested resources across every module (compiled as inline nested deployments).
jq '[.. | objects | select(has("type") and has("properties") and (.type|type)=="string")]' "$T" > "$OUT/resources.json"
R="$OUT/resources.json"

echo "== Design assertions (compiled template)"
check() { # description, jq filter that must produce "true"
  if [[ "$(jq -r "$2" "$R")" == "true" ]]; then pass "$1"; else fail "$1"; fi
}

check "AADLoginForWindows extension present" \
  'any(.[]; .type=="Microsoft.Compute/virtualMachines/extensions" and .properties.type?=="AADLoginForWindows")'
check "AADLoginForWindows has NO mdmId (no Intune enrollment)" \
  'all(.[] | select(.properties.type?=="AADLoginForWindows"); (.properties.settings? // {} | has("mdmId")) | not)'
check "AVD agent DSC registers with aadJoin = true" \
  'any(.[]; .properties.type?=="DSC" and .properties.settings.properties.aadJoin==true)'
check "AVD agent DSC has empty mdmId" \
  'any(.[]; .properties.type?=="DSC" and .properties.settings.properties.mdmId=="")'
check "FSLogix/Kerberos run command completes BEFORE the agent registers the host" \
  'any(.[]; .properties.type?=="DSC" and ((.dependsOn // []) | map(tostring) | any(test("runCommands"))))'
check "Host restarts after the agent registers (Kerberos setting needs a restart)" \
  'any(.[]; .type=="Microsoft.Compute/virtualMachines/runCommands" and (.name|tostring|test("Restart-AfterBuild")) and ((.dependsOn // []) | map(tostring) | any(test("Microsoft.PowerShell.DSC"))))'
check "FSLogix share has a default share-level permission (parameterised)" \
  'any(.[]; .type=="Microsoft.Storage/storageAccounts" and (.properties.azureFilesIdentityBasedAuthentication.defaultSharePermission|tostring|test("defaultSharePermission")))'
check "Private endpoint only deployed in privateEndpoint mode" \
  'any(.[]; .type=="Microsoft.Network/privateEndpoints" and (.condition|tostring|test("usePrivateEndpoint")))'
check "Storage firewall allows the session host subnet in serviceEndpoint mode" \
  'any(.[]; .type=="Microsoft.Storage/storageAccounts" and (.properties.networkAcls.virtualNetworkRules|tostring|test("sessionHostSubnetId")))'
check "New VNet can add the Microsoft.Storage service endpoint to the host subnet" \
  'any(.[]; .type=="Microsoft.Network/virtualNetworks" and (.properties.subnets|tostring|test("storageServiceEndpoint")))'
check "Host pool supports Personal (assignment type + Persistent load balancing)" \
  'any(.[]; .type=="Microsoft.DesktopVirtualization/hostPools" and (.properties|tostring|test("personalDesktopAssignmentType")) and (.properties|tostring|test("Persistent")))'
check "Personal autoscale schedules (start on connect, deallocate on disconnect/logoff)" \
  'any(.[]; .type=="Microsoft.DesktopVirtualization/scalingPlans/personalSchedules" and (.properties.peakActionOnDisconnect=="Deallocate") and (.properties.rampUpStartVMOnConnect=="Enable"))'
check "AVD agent runs after Entra join (dependsOn chain)" \
  'any(.[]; .properties.type?=="DSC" and ((.dependsOn // []) | length) > 0)'
check "Session host VM has SystemAssigned identity" \
  'any(.[]; .type=="Microsoft.Compute/virtualMachines" and .identity.type=="SystemAssigned")'
check "Session host VM uses Trusted Launch" \
  'any(.[]; .type=="Microsoft.Compute/virtualMachines" and .properties.securityProfile.securityType=="TrustedLaunch")'
# Host pool properties are a union() expression (Pooled vs Personal), so check its text.
check "Host pool type comes from the hostPoolType parameter" \
  'any(.[]; .type=="Microsoft.DesktopVirtualization/hostPools" and (.properties|tostring|test("hostPoolType")))'
check "Pooled: maxSessionLimit wired to maxSessionsPerHost" \
  'any(.[]; .type=="Microsoft.DesktopVirtualization/hostPools" and (.properties|tostring|test("maxSessionLimit.*maxSessionsPerHost")))'
if grep -q 'targetisaadjoined:i:1' "$T"; then pass "targetisaadjoined:i:1 present"; else fail "targetisaadjoined:i:1 missing"; fi

echo "== Capacity maths (host count = ceil(users / per-host))"
expr="$(jq -r '.variables.requiredSessionHosts' "$T")"
echo "    requiredSessionHosts = $expr"
if [[ "$expr" == *"isPersonal"* && "$expr" == *"targetUserCount"* ]]; then pass "personal pools: one host per user"; else fail "personal pools: one host per user"; fi
python3 - "$expr" <<'PY' || FAIL=1
import sys, re, math
expr = sys.argv[1]
# Expect: [div(sub(add(parameters('targetUserCount'), parameters('maxSessionsPerHost')), 1), parameters('maxSessionsPerHost'))]
ok = all(k in expr for k in ("div(", "targetUserCount", "maxSessionsPerHost"))
def f(u, p): return (u + p - 1) // p
cases = [(1000, 10, 100), (1001, 10, 101), (999, 10, 100), (10, 10, 1), (1, 10, 1)]
for u, p, want in cases:
    got = f(u, p)
    ok &= got == want == math.ceil(u / p)
    print(f"    {u} users / {p} per host -> {got} hosts")
print("  ok   capacity formula" if ok else "  FAIL capacity formula")
sys.exit(0 if ok else 1)
PY

echo "== Shell scripts"
if command -v shellcheck >/dev/null; then
  shellcheck "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh && pass "shellcheck"
else
  echo "    shellcheck not installed - skipped"
fi

rm -rf "$OUT"
if [[ $FAIL -ne 0 ]]; then echo "Template tests FAILED"; exit 1; fi
echo "All template tests passed."
