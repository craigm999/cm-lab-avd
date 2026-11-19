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
  - runs `Deploy-Avd.ps1` against a stubbed Azure CLI to check the commands it issues and its password handling
  - compiles the generated parameter files and checks their values

The workflow can't run a real deployment: there are no Azure credentials in CI. Run `Deploy-Avd.ps1 -WhatIf` (or `deploy.sh ... what-if`) against your subscription for that.

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
  Deploy-Avd.ps1             # deploy / -WhatIf / -AddHosts / -InfraOnly (Windows PowerShell)
  Update-SessionHostConfig.ps1  # re-apply FSLogix/Kerberos settings to existing hosts
  deploy.sh                  # same, for macOS / Linux
  Enable-EntraSSO.ps1        # one-off tenant config for Entra SSO
```

### How "Entra joined, no Intune" is implemented

Each VM has a **system-assigned managed identity**, and the deployment installs these extensions in order:

1. **`AADLoginForWindows`**: joins the VM to Microsoft Entra ID. The extension gets **no `mdmId` setting**, so the device is *not* enrolled in Intune.
2. **Run command**: applies the FSLogix and Entra Kerberos registry settings. Intune would normally push these settings, so here they are set directly. This happens *before* registration, so no user can land on a half-configured host.
3. **AVD DSC**: installs the AVD agent and registers the VM with the host pool, using `aadJoin: true` and `mdmId: ''`.

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

### From Windows (PowerShell)

You need the Azure CLI (`winget install -e --id Microsoft.AzureCLI`; open a new terminal afterwards). The scripts work in Windows PowerShell 5.1 and PowerShell 7. If script execution is blocked, run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or `Unblock-File` the downloaded scripts.

```powershell
az login
```

```powershell
.\scripts\New-AvdParameterFile.ps1
```

Preview the changes:

```powershell
.\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf
```

Deploy:

```powershell
.\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam
```

`Deploy-Avd.ps1`:
- reads the subscription from the `// subscriptionId:` line in the parameter file (`-SubscriptionId` overrides it)
- prompts for the session host local admin password with hidden input, and removes it from the session when it finishes
- registers any missing resource providers
- asks you to type `yes` before a real deployment (`-Force` skips this)
- prints the deployment outputs at the end

### From macOS / Linux (bash)

```bash
export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'
```

```bash
./scripts/deploy.sh infra/params/prod.bicepparam what-if
```

```bash
./scripts/deploy.sh infra/params/prod.bicepparam
```

The questionnaire looks up the object ID of the **Azure Virtual Desktop** service principal (appId `9cdead84-a844-4324-93f2-b2e6bb768d07`). The deployment grants that principal *Desktop Virtualization Power On Off Contributor*, which autoscale and Start VM on Connect need.

Session hosts deploy 20 at a time. A full 100-host deployment takes roughly 45–90 minutes.

### Pilot with one host, then add the rest

1. **Pilot run.** Answer `1` to the questionnaire's *"Hosts to deploy in the first run"*, or set these values in the parameter file:
   ```bicep
   param sessionHostCountOverride = 1
   param sessionHostStartIndex = 0
   ```
   This deploys everything except the other 99 hosts: host pool, app group, workspace, scaling plan, storage, network, RBAC and `avdsh-001`. You can test sign-in, SSO, FSLogix profiles and outbound access end to end. The pilot needs only 8 vCPU of quota.

2. **Keep the pilot host on while testing.** Autoscale can power off a single host outside business hours. Tag the VM `ExcludeFromScaling` (the plan's exclusion tag), or set `deployScalingPlan = false` for the pilot run. Start VM on Connect wakes a stopped host when someone signs in either way.

3. **Add the remaining hosts.**
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -AddHosts 99 -WhatIf
   ```
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -AddHosts 99
   ```
   This creates `avdsh-002` to `avdsh-100` and leaves `avdsh-001` untouched. Zone placement continues round-robin, so the final spread is still 34/33/33. Raise the vCPU quota to 800 before this run. You can also add hosts in batches (`-AddHosts 20`, then `-AddHosts 20`, …).

   On macOS/Linux with `deploy.sh`, set `sessionHostStartIndex = 1` and `sessionHostCountOverride = 99` in the file instead.

Each run refreshes the host pool registration token (valid for 8 hours by default).

## Updating an existing deployment

Keep **one parameter file per environment** (for example `infra/params/prod.bicepparam`) as the source of truth. Change it, preview with `-WhatIf`, then deploy. Re-run the questionnaire with `-AnswersFile infra/params/prod.answers.json` if you'd rather answer prompts than edit the file.

Two rules keep updates safe:

- **Don't touch existing hosts by accident.** Use `-AddHosts` or `-InfraOnly`. Without them, a run that includes host numbers that already exist re-runs those hosts' setup steps. Azure refuses that on hosts autoscale has stopped, so the run fails. `Deploy-Avd.ps1` warns and asks before doing it.
- **Make changes in the parameter file, not the portal.** The deployment re-applies host pool, app group and scaling plan settings, so a portal change is reverted on the next run.

Deployments are incremental. Resources you remove from the template, or switch off (for example `deployFslogixStorage = false`), are **not** deleted. Delete them yourself if you really mean to.

| I want to… | Do this |
|---|---|
| **Add more hosts** | `.\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -AddHosts 20 -WhatIf`, then without `-WhatIf`. It finds the highest existing host (e.g. `avdsh-100`) and adds `avdsh-101` to `avdsh-120`, continuing the zone spread. Check vCPU quota and free subnet IPs first. Raise `targetUserCount` in the file too, so the file still describes the environment. |
| **Add FSLogix profiles** to a deployment that didn't have them | See the steps below. |
| **Change host pool settings** (max sessions, load balancing, RDP properties, SSO, scaling schedule) | Edit the parameter file (schedules are in `infra/modules/hostpool.bicep`), then run `Deploy-Avd.ps1 -InfraOnly`. Takes effect immediately. A lower max sessions limit applies to new connections. |
| **Change profile size or share path** on existing hosts | Edit the file, then run `Deploy-Avd.ps1 -InfraOnly` (if storage changed) and `Update-SessionHostConfig.ps1 -IncludeStopped`. |
| **New image, VM size or Windows build** | Replace hosts rather than changing them in place. Run `-AddHosts N` with the new `imageReference` / `vmSize` in the file. In the portal, set the old hosts to drain mode (*Host pool → Session hosts → Turn off new sessions*). Once they're empty, delete them (VM, NIC and disk are removed together). Users never sit on a host that's mid-change. |
| **Remove hosts** | Drain mode first. When the host has no sessions, delete the VM in the portal and remove the session host from the host pool. Numbers aren't reused unless you set `sessionHostStartIndex` yourself. |

### Adding FSLogix profiles after the first deployment

1. **Turn it on in the parameter file:**
   ```bicep
   param deployFslogixStorage = true
   param privateDnsZoneMode = 'new'   // or 'existing' + existingFilePrivateDnsZoneId, or 'policyManaged'
   param resourceGroups = {
     ...
     storage: { name: '', create: true }
   }
   ```
   You can also re-run the questionnaire with `-AnswersFile` and answer *yes* to FSLogix.
2. **Create the storage without touching hosts:**
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -InfraOnly -WhatIf
   ```
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -InfraOnly
   ```
   This saves the new share path into `prod.outputs.json`.
3. **Do the storage post-deployment steps** (below): admin consent, Conditional Access exclusion, NTFS permissions. Check from one host that `\\<storage>.file.core.windows.net\profiles` resolves to the private IP and opens.
4. **Push the FSLogix settings to the existing hosts:**
   ```powershell
   .\scripts\Update-SessionHostConfig.ps1 -ParameterFile .\infra\params\prod.bicepparam -IncludeStopped
   ```
   Hosts are Entra-joined with no Intune or Group Policy, so this script delivers the settings. It runs the same `Configure-SessionHost` run command the template uses on every host. `-IncludeStopped` starts hosts autoscale has switched off, because a stopped host can't receive the settings. Autoscale powers them down again later.

Hosts added later get FSLogix automatically during deployment.

> **Users' existing local profiles are not migrated.** On their next sign-in after step 4, each user gets a new, empty FSLogix profile, and the old local copy on that host is removed (`DeleteLocalProfileWhenVHDShouldApply`). On pooled hosts users usually expect this, but warn them. Run step 4 out of hours, because settings apply at the next sign-in and existing sessions are unaffected.

## Firewall rules

No inbound rules are needed. If outbound traffic goes through a firewall (hub firewall mode, or an existing VNet behind one), allow the endpoints in [`docs/firewall-rules.md`](docs/firewall-rules.md) before the pilot. If the Entra join and agent endpoints are blocked, the host deployment fails.

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
