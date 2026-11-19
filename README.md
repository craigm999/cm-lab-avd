# cm-lab-avd

Bicep deployment for an **Azure Virtual Desktop** environment with:

- **Microsoft Entra ID joined** session hosts, **no Intune enrollment**
- A **pooled** host pool, **10 users per host**
- Capacity for **1,000 concurrent users**, so **100 session hosts**
- FSLogix profile containers on Azure Files Premium using **Microsoft Entra Kerberos**, so no domain controllers are needed
- Autoscale scaling plan, so 100 hosts don't run around the clock
- Private networking: no inbound ports, and a private endpoint for storage
- Works with **new or existing** resource groups, VNet, Log Analytics workspace and private DNS zone, so it can go into an existing landing zone

## Architecture diagram

`docs/avd-build-map.html` is an interactive diagram. Open it in a browser and toggle new or existing VNet, egress, hub peering, Log Analytics, DNS, FSLogix and autoscale to see what gets created, what is only referenced, and where traffic flows.

## Testing

`.github/workflows/validate.yml` runs on every push:

- **Bicep** (`tests/test-template.sh`):
  - compiles and lints `main.bicep`
  - builds every scenario parameter file in `tests/params/` (greenfield, hub-spoke with a shared resource group, minimal)
  - checks the compiled ARM JSON for the design requirements: Entra join with no Intune `mdmId`, the agent registering with `aadJoin: true`, a pooled host pool, and the host count formula
- **PowerShell** (`tests/Test-PowerShell.ps1`):
  - parses every script and runs PSScriptAnalyzer
  - runs the questionnaire end to end with scripted answers for two scenarios
  - compiles the generated parameter files and checks their values

The workflow can't run a real deployment: there are no Azure credentials in CI. Run `./scripts/deploy.sh <params> what-if` against your subscription for that.

## Start here: the questionnaire

Collect the environment details first. You can do this in one of two ways:

- **Interactive:** run `pwsh ./scripts/New-AvdParameterFile.ps1`. It asks each question and writes `infra/params/<env>.bicepparam` plus `<env>.answers.json`. If you're signed in with `az`, it also:
  - offers subscriptions, VNets, subnets, workspaces and DNS zones as pick lists
  - detects resource groups that already exist
  - checks subnet free IPs and vCPU quota
  - resolves Entra group names to object IDs
- **On paper:** fill in [`docs/questionnaire.md`](docs/questionnaire.md), for example by sending it to the customer, then run the script with the answers.

Re-run the script with `-AnswersFile infra/params/<env>.answers.json` to change answers. Your previous answers become the defaults.

## Architecture

Resource group names are configurable. Each one can be **created** or **existing**, and several components can share a group. The defaults are:

| Resource group | Contents |
|---|---|
| `rg-avd-prod-<region>-service` | Host pool (Pooled, `maxSessionLimit` 10), Desktop app group, Workspace, Scaling plan |
| `rg-avd-prod-<region>-hosts` | 100 × Windows 11 multi-session + M365 VMs (Trusted Launch, spread over zones 1/2/3) |
| `rg-avd-prod-<region>-network` | **New-VNet mode only:** VNet `10.50.0.0/16`, hosts subnet `/22`, PE subnet `/27`, NSGs, and either a NAT gateway or a UDR to the hub firewall. Optional hub peering in both directions. |
| `rg-avd-prod-<region>-storage` | Premium FileStorage account (Entra Kerberos), `profiles` share, private endpoint. The DNS zone is new, existing (central) or policy-managed. |
| `rg-avd-prod-<region>-monitor` | **New-workspace mode only:** Log Analytics. Otherwise diagnostics go to your existing workspace, which can be in any subscription. |

### Existing vs new: the key switches

| Parameter | Options |
|---|---|
| `resourceGroups.<role>` | `{ name, create }` for service, hosts, storage, network, monitor |
| `networkMode` | `existing` (with `existingSessionHostSubnetId` and `existingPrivateEndpointSubnetId`) or `new` (with `outboundMethod` NatGateway/FirewallUdr/None, `dnsServers`, `hubVnetId`) |
| `logAnalyticsMode` | `existing` (`existingLogAnalyticsWorkspaceId`) or `new` |
| `privateDnsZoneMode` | `new`, `existing` (`existingFilePrivateDnsZoneId`) or `policyManaged` |

> **Subscription rule:** deploy into the subscription that holds the session host VNet. Azure doesn't allow a VM NIC or a private endpoint to use a VNet in a different subscription. The Log Analytics workspace, private DNS zone and hub VNet can be in other subscriptions.

```
docs/
  questionnaire.md           # fill-in questionnaire (subscriptions, RGs, VNets, ...)
infra/
  main.bicep                 # subscription-scope entry point
  main.bicepparam            # example: existing VNet / Log Analytics / central DNS
  params/                    # generated <env>.bicepparam + <env>.answers.json
  modules/
    network.bicep            # new VNet only
    vnet-peering.bicep       # spoke<->hub peering (hub may be in another subscription)
    monitoring.bicep
    hostpool.bicep           # host pool, app group, workspace, scaling plan, diagnostics
    storage.bicep            # FSLogix Azure Files + Entra Kerberos + private endpoint
    hosts-rbac.bicep         # VM login roles + AVD power on/off role
    sessionhost.bicep        # one VM: Entra join -> AVD agent -> FSLogix config
  scripts/
    Configure-SessionHost.ps1  # run command: FSLogix + Kerberos registry settings
scripts/
  New-AvdParameterFile.ps1   # interactive questionnaire -> infra/params/<env>.bicepparam
  deploy.sh                  # wrapper around az deployment sub create / what-if
  Enable-EntraSSO.ps1        # one-off tenant config for Entra SSO
```

### How "Entra joined, no Intune" is implemented

Each VM has a **system-assigned managed identity**, and the deployment installs these extensions in order:

1. **`AADLoginForWindows`**: joins the VM to Microsoft Entra ID. The extension gets **no `mdmId` setting**, so the device is *not* enrolled in Intune.
2. **AVD DSC**: installs the AVD agent and registers the VM with the host pool, using `aadJoin: true` and `mdmId: ''`.
3. **Run command**: applies the FSLogix and Entra Kerberos registry settings. Intune would normally push these settings, so here they are set directly.

The host pool's RDP properties include `targetisaadjoined:i:1` and, when SSO is enabled, `enablerdsaadauth:i:1`.

## Sizing

| Setting | Value |
|---|---|
| Target users | 1,000 |
| Max sessions per host | 10 |
| Session hosts | `ceil(1000 / 10)` = **100**, calculated in `main.bicep` |
| VM size | `Standard_D8s_v5` (8 vCPU / 32 GiB). That is about 1.25 users per vCPU, which leaves plenty of headroom for medium or heavy users |
| vCPU quota needed | **800 vCPU** of *Standard DSv5 Family* plus the matching *Total Regional vCPUs* |
| FSLogix share | 10 TiB Premium ZRS, about 13k baseline IOPS. The 30 GB VHDX cap per user is dynamically sized |

If your users are light task workers, `Standard_D4s_v5` halves the compute cost. Change `vmSize`.

## Prerequisites

1. Azure CLI 2.60 or later with Bicep (`az bicep upgrade`), and PowerShell 7 (`pwsh`) or Windows PowerShell 5.1 for the questionnaire. The `resource-graph` extension is optional (`az extension add -n resource-graph`) and enables cross-subscription pick lists.
2. **Owner** or **User Access Administrator + Contributor** on the workload subscription, because the deployment creates role assignments. You also need **Network Contributor** on the hub VNet if the deployment peers a new VNet to it, and **Private DNS Zone Contributor** on a central DNS zone if you use one.
3. A **vCPU quota increase**: 800 cores of DSv5 in the target region. Request it before you deploy.
4. An Entra ID **security group of AVD users**, and optionally an admins group.
5. Check `avdAgentDscPackageUrl` in `main.bicep`. Microsoft periodically publishes a new `Configuration_*.zip`, and the current URL is in the portal's "Add session host" template.

## Deploy

```bash
az login
```

```bash
pwsh ./scripts/New-AvdParameterFile.ps1
```

```bash
export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'
```

Preview the changes:

```bash
./scripts/deploy.sh infra/params/prod.bicepparam what-if
```

Deploy:

```bash
./scripts/deploy.sh infra/params/prod.bicepparam
```

`deploy.sh` reads the target subscription from the `// subscriptionId:` line at the top of the parameter file. Set `AVD_SUBSCRIPTION_ID` to override it.

The questionnaire looks up the object ID of the **Azure Virtual Desktop** service principal (appId `9cdead84-a844-4324-93f2-b2e6bb768d07`). The deployment grants that principal *Desktop Virtualization Power On Off Contributor*, which autoscale and Start VM on Connect need.

Session hosts deploy 20 at a time. A full 100-host deployment takes roughly 45–90 minutes.

### Staged rollout or scaling out later

Deploy a pilot first, then the remaining hosts:

The questionnaire asks for a pilot size. To deploy the remaining hosts later:

```bash
./scripts/deploy.sh infra/params/prod.bicepparam create -p sessionHostStartIndex=20 sessionHostCountOverride=80
```

Each run refreshes the host pool registration token (valid for 8 hours by default).

## Post-deployment steps (required)

These steps can't be fully expressed in ARM/Bicep:

1. **Grant admin consent for the storage account's Entra app.** In Entra ID, open *App registrations → All applications* and find `[Storage Account] <name>.file.core.windows.net`. Under *API permissions*, grant admin consent.
2. **Exclude that storage app from Conditional Access policies that require MFA.** Otherwise, Kerberos ticket retrieval for the FSLogix share fails.
3. **Set NTFS permissions on the `profiles` share** for the FSLogix creator/owner pattern. Use an admin who holds *Storage File Data SMB Share Elevated Contributor* (the admins group is granted this). See Microsoft's "Configure FSLogix profile container with Azure Files and Microsoft Entra ID" guidance.
   - Identity support: Entra Kerberos for Azure Files is generally available for **hybrid** identities (users synced from AD). Support for **cloud-only** users is newer. Check its current status for your tenant before relying on it for FSLogix.
4. **Optional: suppress the SSO consent prompt.** Create a group (dynamic or assigned) containing the session host devices, then run:
   ```powershell
   ./scripts/Enable-EntraSSO.ps1 -TargetDeviceGroupId <device group id>
   ```
5. **If `privateDnsZoneMode` is `existing`:** confirm the central zone is linked to the VNet that provides DNS for the session hosts, and that `<storage>.file.core.windows.net` resolves to the private IP from a host.

## Connecting

Users subscribe in Windows App or the Remote Desktop client, or use the web client at `https://windows.cloud.microsoft`. Because the hosts are Entra-joined, the client device must be Entra joined or registered, or SSO (`enablerdsaadauth`) must be enabled, which is the default here.

## Things you might want to change

| Parameter | Default | Notes |
|---|---|---|
| `loadBalancerType` | `BreadthFirst` | Use `DepthFirst` to pack hosts and maximise autoscale savings |
| `scalingPlanTimeZone` / schedule | GMT, 07:00–20:00 weekdays | Edit the schedule in `modules/hostpool.bicep` |
| `imageReference` | Win 11 24H2 multi-session + M365 | Swap in an Azure Compute Gallery image for production |
| `encryptionAtHost` | `false` | Requires `Microsoft.Compute/EncryptionAtHost` feature registration |
