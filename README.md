# cm-lab-avd

Bicep deployment for an **Azure Virtual Desktop** environment with:

- **Microsoft Entra ID joined** session hosts, **no Intune enrollment**
- A **pooled** host pool, **10 users per host**
- Capacity for **1,000 concurrent users**, so **100 session hosts**
- FSLogix profile containers on Azure Files Premium using **Microsoft Entra Kerberos**, so no domain controllers are needed
- Autoscale scaling plan, so 100 hosts don't run around the clock
- Private networking: no inbound ports, NAT gateway for outbound traffic, and a private endpoint for storage

## Architecture

| Resource group | Contents |
|---|---|
| `rg-avd-prod-<region>-service` | Host pool (Pooled, `maxSessionLimit` 10), Desktop app group, Workspace, Scaling plan |
| `rg-avd-prod-<region>-hosts` | 100 × Windows 11 multi-session + M365 VMs (Trusted Launch, spread over zones 1/2/3) |
| `rg-avd-prod-<region>-network` | VNet `10.50.0.0/16`, hosts subnet `/22`, PE subnet `/27`, NSGs, NAT gateway |
| `rg-avd-prod-<region>-storage` | Premium FileStorage account (Entra Kerberos), `profiles` share, private endpoint + DNS zone |
| `rg-avd-prod-<region>-monitor` | Log Analytics workspace (diagnostics from host pool, app group, workspace, scaling plan, files) |

```
infra/
  main.bicep                 # subscription-scope entry point
  main.bicepparam            # parameter values (secrets come from env vars)
  modules/
    network.bicep
    monitoring.bicep
    hostpool.bicep           # host pool, app group, workspace, scaling plan, diagnostics
    storage.bicep            # FSLogix Azure Files + Entra Kerberos + private endpoint
    hosts-rbac.bicep         # VM login roles + AVD power on/off role
    sessionhost.bicep        # one VM: Entra join -> AVD agent -> FSLogix config
  scripts/
    Configure-SessionHost.ps1  # run command: FSLogix + Kerberos registry settings
scripts/
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

1. Azure CLI 2.60 or later with Bicep (`az bicep upgrade`).
2. **Owner** or **User Access Administrator + Contributor** on the subscription, because the deployment creates role assignments.
3. A **vCPU quota increase**: 800 cores of DSv5 in the target region. Request it before you deploy.
4. An Entra ID **security group of AVD users**, and optionally an admins group.
5. Check `avdAgentDscPackageUrl` in `main.bicep`. Microsoft periodically publishes a new `Configuration_*.zip`, and the current URL is in the portal's "Add session host" template.

## Deploy

```bash
az login
```

```bash
az account set --subscription "<subscription id>"
```

```bash
export AVD_LOCAL_ADMIN_PASSWORD='<strong password>'
export AVD_USERS_GROUP_ID='<users group object id>'
export AVD_ADMINS_GROUP_ID='<admins group object id>'   # optional
export LOCATION='uksouth'
```

Preview the changes:

```bash
./scripts/deploy.sh what-if
```

Deploy:

```bash
./scripts/deploy.sh
```

The script looks up the **Azure Virtual Desktop** service principal (appId `9cdead84-a844-4324-93f2-b2e6bb768d07`). It then grants that principal *Desktop Virtualization Power On Off Contributor*, which autoscale and Start VM on Connect need.

Session hosts deploy 20 at a time. A full 100-host deployment takes roughly 45–90 minutes.

### Staged rollout or scaling out later

Deploy a pilot first, then the remaining hosts:

```bash
# Run 1: hosts 001-020
az deployment sub create -l uksouth -f infra/main.bicep -p infra/main.bicepparam \
  -p sessionHostCountOverride=20 sessionHostStartIndex=0
```

```bash
# Run 2: hosts 021-100
az deployment sub create -l uksouth -f infra/main.bicep -p infra/main.bicepparam \
  -p sessionHostCountOverride=80 sessionHostStartIndex=20
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
5. **Optional: if you already have a central `privatelink.file.core.windows.net` zone** in a hub, remove the zone from `storage.bicep` and link the private endpoint to your existing zone.

## Connecting

Users subscribe in Windows App or the Remote Desktop client, or use the web client at `https://windows.cloud.microsoft`. Because the hosts are Entra-joined, the client device must be Entra joined or registered, or SSO (`enablerdsaadauth`) must be enabled, which is the default here.

## Things you might want to change

| Parameter | Default | Notes |
|---|---|---|
| `loadBalancerType` | `BreadthFirst` | Use `DepthFirst` to pack hosts and maximise autoscale savings |
| `scalingPlanTimeZone` / schedule | GMT, 07:00–20:00 weekdays | Edit the schedule in `modules/hostpool.bicep` |
| `imageReference` | Win 11 24H2 multi-session + M365 | Swap in an Azure Compute Gallery image for production |
| `encryptionAtHost` | `false` | Requires `Microsoft.Compute/EncryptionAtHost` feature registration |
| `dnsServers` | Azure DNS | Set this if you route DNS through a hub |
