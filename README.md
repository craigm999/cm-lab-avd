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
  Test-AvdUserAccess.ps1     # read-only: why can't this user see / open the desktop?
  Set-FslogixStorageAuth.ps1 # one-off Entra app setup for FSLogix (privatelink, consent, CA check)
  Get-FslogixHostDiagnostics.ps1 # read-only: why won't profiles load on this host?
  Publish-AvdPoolAutomation.ps1 # publishes the spares/tidy-up runbook (run by Deploy-Avd.ps1)
  Get-HostDataProtectionReport.ps1 # read-only: which DLP settings are really in effect on a host
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

## Personal (1:1) desktops

Set `hostPoolType = 'Personal'` and every user gets their own VM instead of sharing multi-session hosts.

| | Pooled (default) | Personal |
|---|---|---|
| Hosts | `ceil(users / maxSessionsPerHost)`, e.g. 100 for 1,000 users | **One VM per user**, e.g. 1,000 for 1,000 users |
| Suggested size | `Standard_D8s_v5` (10 users each) | `Standard_D4s_v5` (D2s_v5 for light use) |
| vCPU quota for 1,000 users | 800 | **4,000** with D4s_v5 |
| User profiles | FSLogix on Azure Files | On the user's own VM. FSLogix is off by default and optional. |
| Assignment | Load-balanced | `personalAssignmentType`: **Automatic** (a user gets a free desktop on first connection) or **Direct** (you assign) |
| Autoscale | Hosts on and off by demand | Each VM starts when its user connects. It's deallocated 15 min after sign-out or 2 h after a disconnect (shorter out of hours). |

The type of an existing host pool can't be changed, so a personal deployment creates its **own** host pool, app group and scaling plan (`…-personal`). It reuses everything else: network, resource groups, Log Analytics, role assignments and the **workspace**.

### Moving from pooled to personal

1. **Create a parameter file for personal.** Re-run the questionnaire with your previous answers as defaults and choose *Personal*:
   ```powershell
   .\scripts\New-AvdParameterFile.ps1 -AnswersFile .\infra\params\prod.answers.json
   ```
   Or set `hostPoolType = 'Personal'`, `personalAssignmentType`, `sessionHostNamePrefix = 'avdpd'` (so names don't clash with the pooled `avdsh-*` hosts), `vmSize` and `deployFslogixStorage = false` in a copy of your file.
2. **Deploy a pilot**, e.g. `sessionHostCountOverride = 2`:
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf
   ```
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam
   ```
   The workspace now publishes the **personal** desktop, and the pooled one disappears from users' feeds.
3. **Assign users** (Direct only; Automatic assigns on first connection):
   ```powershell
   .\scripts\Set-AvdPersonalAssignment.ps1 -ParameterFile .\infra\params\prod.bicepparam -FromGroup 'AVD Users' -WhatIf
   ```
   It gives every group member who has no desktop yet the next free one. You can also use `-User` with `-SessionHost`, or `-CsvPath` with columns `User,SessionHost`. `Test-AvdUserAccess.ps1` shows whether a user has a desktop assigned.
4. **Scale out in batches of up to 400.** ARM allows 800 resources per deployment, and `Deploy-Avd.ps1` refuses larger single runs:
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -AddHosts 400
   ```
   Repeat until you have one VM per user. Request the vCPU quota first.
5. **Remove the pooled deployment** once nobody uses it. The template doesn't delete anything:
   - **Session hosts:** delete the `avdsh-*` VMs. Deleting a VM removes its NIC and disk. Then remove them from the pooled host pool (*Host pool → Session hosts*).
   - **Pooled AVD objects:** delete the pooled scaling plan, then the app group `vdag-…-desktop`, then the host pool `vdpool-…` (without `-personal`).
   - **Entra devices:** delete the `avdsh-*` objects in *Entra ID → Devices*.
   - **FSLogix (optional):** delete the storage account and its `[Storage Account] …` app registration if nothing else uses them.

**Notes:**
- **Profiles live on the VM.** If a personal VM is rebuilt, its profile goes with it. Use OneDrive Known Folder Move, or keep FSLogix (`deployFslogixStorage = true`), if user data must survive a rebuild.
- **Image:** the default Windows 11 *multi-session* + Microsoft 365 image works for personal pools. For single-session, set `imageReference` to e.g. `MicrosoftWindowsDesktop` / `windows-11` / `win11-24h2-ent` (no Microsoft 365 Apps preinstalled).
- **Start VM on Connect** is enabled. It needs the AVD service principal's *Power On Off Contributor* role, which the deployment assigns when `avdServicePrincipalObjectId` is set.

## Customising session hosts (apps, optimisation, hardening)

Each new host is customised **during its build**, after the Entra join and profile configuration and **before** the AVD agent registers it. Users only ever land on finished desktops. Everything is driven by one file, [`infra/customizations/customizations.json`](infra/customizations/customizations.json), and the script [`infra/scripts/Customize-SessionHost.ps1`](infra/scripts/Customize-SessionHost.ps1). Turn it off with `applyCustomizations = false`.

| Section | What it does |
|---|---|
| `optimize` | Turns off consumer features, tips and the first-logon animation. Removes the built-in Appx packages listed in `removeAppxPackages` (Xbox, Solitaire, Clipchamp, …). Edit the list to keep any you want. |
| `harden` | Turns off LLMNR, AutoRun and WDigest cleartext credentials. Turns on LSA protection, Defender PUA protection, the firewall (all profiles) and logon auditing. `defenderNetworkProtection: true` adds Defender network protection; test it with your apps first. |
| `apps` | Downloads and silently installs MSI or EXE installers. **Give a `sha256` for each one**: the script refuses a download whose hash doesn't match. Use `detectPath` to skip apps that are already installed. |

Example `apps` entry:

```json
"apps": [
  {
    "name": "7-Zip",
    "url": "https://www.7-zip.org/a/7z2409-x64.msi",
    "arguments": "",
    "sha256": "<SHA-256 of that file>",
    "detectPath": "C:\\Program Files\\7-Zip\\7z.exe"
  }
]
```

Get a file's hash with `(Get-FileHash .\file.msi -Algorithm SHA256).Hash`.
- **Host access:** the hosts must be able to reach each `url`. Allow it through your firewall, or host installers in your own storage account.
- **Build time:** every app adds download and install time to each host's build. That's the main argument for a custom image if the list grows.

**Adding apps.** Let the helper download the installer once on your machine, compute its SHA-256 and write the entry:

```powershell
.\scripts\Add-CustomizationApp.ps1 -Name 'Git' `
    -Url 'https://github.com/git-for-windows/git/releases/download/v<version>.windows.1/Git-<version>-64-bit.exe' `
    -Arguments '/VERYSILENT /NORESTART /NOCANCEL /SP-' -DetectPath 'C:\Program Files\Git\cmd\git.exe'
```

For a new version later, run it again with the new `-Url` and `-Replace`. That updates the hash and keeps the entry's other settings.

Extra fields for installers that need more than a URL:

| Field | Use |
|---|---|
| `fileName` | The URL has no file name, e.g. VS Code's `…/win32-x64/stable`. Tells the script it's `VSCodeSetup-x64.exe`. |
| `files` | Small config files written next to the installer, e.g. JetBrains' `silent.config`. Refer to that folder as `{dir}` in `arguments`. |
| `registry` | Settings applied after install, e.g. VS Code's `UpdateMode = none` policy. Users on AVD aren't admins, so in-app updaters for machine-wide installs can't work. Update by bumping the version instead. |

[`infra/customizations/examples/developer-apps.json`](infra/customizations/examples/developer-apps.json) has working entries for **VS Code** (system installer + update policy), **Git** and **IntelliJ IDEA Community** (`silent.config` for an all-users install). Its versions are examples. Copy the entries into `customizations.json`, then run `Add-CustomizationApp.ps1 -Name … -Url <current version> -Replace` for each to set the real hash. Until then the placeholder hash makes the install refuse to run. Other JetBrains IDEs use the same pattern with their own download URL. Paid editions need licences. Check each vendor's silent-install documentation for the switches your version supports.

**Optimisation tools (VDOT / WDOT).** The Virtual Desktop Optimization Tool says on its project page that it has been superseded by the Windows Desktop Optimization Tool (WDOT) and receives no more updates. It was last tested against Windows 11 23H2. Its known issues include Start menu, Store, Windows Update and OneDrive problems. Microsoft's own VDI optimisation guide is archived (Windows 10 1607). For VM sizes like D4s_v5 the gains are small, so this deployment applies only a light set (`optimize` above). If you want WDOT, run it while **building a custom image**, where you can test it once, not on every host at build time.

**Applying changes to existing hosts.** The JSON is compiled into the template, so new hosts always get the current version. To push it to hosts that already exist:

```powershell
.\scripts\Update-SessionHostConfig.ps1 -ParameterFile .\infra\params\prod.bicepparam -Customize -IncludeStopped
```

It runs the same script on each host as the `Customize-SessionHost` run command, and the script is safe to re-run. Restart hosts afterwards, out of hours, if an installer or LSA protection needs it. Log on each host: `C:\ProgramData\AvdCustomization\customize.log`.

**Build scripts vs a custom image:**

| | Build scripts (this) | Custom image |
|---|---|---|
| Upkeep | None: always the current Microsoft image | An image pipeline to rebuild, typically monthly |
| Build time | Grows with the app list | Fast |
| Consistency | Depends on download sources staying available | Identical every time |
| Existing personal desktops | Same scripts can be re-pushed | No effect |

Start with build scripts. Move to an image (for example Azure Image Builder running these same scripts) if build times or download reliability become a problem. Neither keeps apps up to date on existing desktops. Without Intune, re-push with `-Customize`, use apps' own updaters (Microsoft 365 Apps updates itself), and use Azure Update Manager for Windows patches.

## Device redirection (drives, printers, USB, …)

Controlled by the `redirection` block in [`infra/customizations/customizations.json`](infra/customizations/customizations.json) (`true` = allowed):

| Setting | Default | Notes |
|---|---|---|
| `drives` | blocked | Local drives in the session |
| `printers` | blocked | Local printers |
| `usbDevices` | blocked | USB and Plug and Play / MTP-PTP devices (phones, cameras as storage) |
| `comPorts` | blocked | COM and LPT ports |
| `smartCards` | blocked | Allow it if users sign in to apps inside the session with a smart card |
| `cameras` | blocked | Webcams. Allow it if users make **Teams video calls** from the desktop. |
| `clipboard` | allowed | Copy/paste both ways |
| `audioPlayback` | allowed | Sound plays on the user's device |
| `microphone` | allowed | Needed for calls |
| `webAuthn` | allowed | Passkeys / Windows Hello for sign-ins inside the session. Authentication, not data. |

Each setting is applied in **two places**, and Microsoft documents that the most restrictive one wins:
1. **Host pool RDP properties**, built by the template from this block. Applied by `Deploy-Avd.ps1` (`-InfraOnly` is enough).
2. **Policy on each session host** (*Remote Desktop Session Host → Device and Resource Redirection*), written by `Customize-SessionHost.ps1`. A client can't opt back in to something blocked on the host. New hosts get it during their build. For existing hosts:
   ```powershell
   .\scripts\Update-SessionHostConfig.ps1 -ParameterFile .\infra\params\prod.bicepparam -Customize -IncludeStopped
   ```

Changes apply to **new sessions**, so users sign out and back in. The registry values the script writes are checked in CI against Windows' own `TerminalServer.admx`: right policy, right state.

## Data protection: other tenants and personal accounts

Conditional Access in your tenant protects **your** resources. It can't stop someone on the desktop signing in to **another** organisation's Microsoft 365, or a personal account, and uploading data there. These controls handle that on the session host. They live in the `dataProtection` block of [`customizations.json`](infra/customizations/customizations.json) and are applied by the same customisation step (new hosts at build; existing hosts with `Update-SessionHostConfig.ps1 -Customize`).

| Setting | Default | Effect |
|---|---|---|
| `blockMicrosoftAccounts` | on | Windows *Accounts: Block Microsoft accounts* = users can't add or sign in with personal Microsoft accounts. Checked in CI against Windows' own definition. |
| `oneDriveOnlyOwnTenant` | on | OneDrive syncs **only your organisation** (`AllowTenantList`), and **personal OneDrive sync is blocked** (`DisablePersonalSync`, set in the default user profile so every new profile gets it). |
| `blockedUrls` | `onedrive.live.com` | Edge URL block list. Consumer OneDrive on the web isn't covered by Tenant Restrictions (Microsoft's documented workaround is blocking this site). Add other personal storage sites as needed, e.g. `dropbox.com`, `drive.google.com`, `wetransfer.com`. |
| `edgeSigninPattern` | empty | Restrict Edge profile sign-in to your accounts, e.g. `.*@contoso\\.com`. This is a case-sensitive regex. |
| `tenantRestrictions` | **off** | **Microsoft Entra Tenant Restrictions v2**: blocks sign-in to any tenant except yours (and personal Microsoft accounts) in Office apps, Edge and all sites in Edge, plus data-plane protection for SharePoint/OneDrive, Exchange and Graph. |
| `tenantId` | empty | Empty = the host's own Entra tenant, read from `dsregcmd`. |

**Turning on Tenant Restrictions v2:**
1. In Entra: *External Identities → Cross-tenant access settings → Default settings → Tenant restrictions*.
   - **Block** external users and applications (all tenants), and save.
   - Copy the **Policy ID**.
   - To use apps from a partner tenant, add that organisation and allow it there.
   - Licensing: Entra ID P1. Permissions: Security Administrator.
2. In `customizations.json`:
   ```json
   "tenantRestrictions": { "enabled": true, "policyId": "<Policy ID>", "firewallProtection": false }
   ```
3. Push it with `Update-SessionHostConfig.ps1 -Customize -IncludeStopped`, then restart the hosts.

Microsoft documents the Windows device option (*Tenant Restrictions → Cloud Policy Details*) as a Group Policy but **not its registry values**, and it is marked **preview**. So the script reads the policy definition that ships with the host's own Windows build. It finds the fields by their documented labels: *Microsoft Entra Directory ID*, *Policy GUID*, *Enable firewall protection of Microsoft endpoints*. It writes only those, and logs what it found. If it can't identify them unambiguously, it fails the step instead of guessing. Check `C:\ProgramData\AvdCustomization\customize.log` on the first host. `firewallProtection` adds the documented firewall enforcement for Microsoft endpoints; test it before turning it on widely.

**"A guest could still sign in to their home-tenant OneDrive."** The tenant restrictions policy in Entra does nothing on its own. It's enforced only when the **device** tells the sign-in service which policy applies, and on these hosts that's the Windows policy the customisation writes. Check what's actually on a host. Run it while a test user is signed in:

```powershell
.\scripts\Get-HostDataProtectionReport.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName <host>
```

It shows:
- whether the latest customisation (with `dataProtection`) ran, and whether a restart is pending;
- the OneDrive allowed tenants;
- the Tenant Restrictions values present, or none;
- which tenant each signed-in user's OneDrive app is syncing.

Usual causes:
1. `tenantRestrictions.enabled` is still `false`, or there's no `policyId`.
2. The host was never pushed the current `customizations.json`.
3. No restart since the push.
4. In Entra, only the *External applications* tab is set to Block. Microsoft says to block on **both** tabs (*External users and groups* too).

OneDrive's `AllowTenantList` blocks syncing another organisation's OneDrive independently of tenant restrictions. If the report shows it set and OneDrive still syncs another tenant, restart OneDrive or sign the user out.

**What this doesn't cover:**
- **Other browsers.** Policies apply to Edge. Don't install other browsers, or apply equivalent policies to them.
- **Your own tenant's data leaving through allowed channels**, such as the clipboard (still allowed) or email. Microsoft Purview DLP (endpoint DLP) covers that, with onboarding and E5-level licensing.
- **Screenshots and photos of the screen.** AVD has *screen capture protection* and *watermarking* for this; they can be added the same way if you want them.

## Custom images

`imageReference` takes either a marketplace image or an **Azure Compute Gallery** image. Microsoft recommends the gallery for production, for replication and versioning.

```bicep
// Latest version of a gallery image definition (new hosts pick up new versions automatically)
param imageReference = {
  id: '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>'
}
// ...or pin one version: .../images/<definition>/versions/1.2.0
param vmSecurityType = 'TrustedLaunch'   // 'Standard' if the image can't use Trusted Launch
```

You can also re-run the questionnaire and choose *gallery*.

**Building the image** (per Microsoft's golden image and Trusted Launch guidance):
- Start from the same Windows 11 Enterprise image (multi-session for pooled). Customise it, then **sysprep (generalize)** it.
- **Don't install the AVD agent** or join the build VM to a host pool. Don't create it with *Login with Microsoft Entra ID*. The deployment does both on each host.
- **Trusted Launch** (the default `vmSecurityType`) needs a **Gen2** image whose definition has security type **`TrustedLaunchSupported`** (recommended) or `TrustedLaunch`. Plain managed images and Gen1 images can't use it; set `vmSecurityType = 'Standard'` for those.
- **Replicate** the image version to the deployment region. The deploying identity needs *Reader* on the gallery, which can be in another subscription.

`Deploy-Avd.ps1` checks all of this before deploying: definition found, generalized, Gen2 and security type compatible with `vmSecurityType`, and the version replicated to the region. It stops with the reason if not.

**Rolling out a new image.** Changing `imageReference` only affects hosts created afterwards. Azure can't change the image of an existing VM, and `Deploy-Avd.ps1` warns before a run would touch existing hosts.
- **Pooled:** run `-AddHosts N` with the new image, set the old hosts to drain mode, and delete them once they're empty. See *Updating an existing deployment*.
- **Personal:** each user's VM keeps its own image, profile and data. Patch personal VMs in place (Windows Update / your update tooling). A new image is for new desktops. Moving an existing user to a new VM means moving their data, unless OneDrive Known Folder Move or FSLogix holds it.

## Desktop name in Windows App

Users see the friendlyName of the desktop resource inside the app group, not the app group's name. That resource (`SessionDesktop`) is read-only in ARM templates, so `Deploy-Avd.ps1` sets it to `desktopFriendlyName` after each deployment. To change the name, edit `desktopFriendlyName` and run `Deploy-Avd.ps1 -InfraOnly`. Users see it after their feed refreshes; sign out of Windows App and back in to force it.

## Pool automation: spare desktops and tidy-up (Personal)

For personal pools, an optional daily job keeps **N spare desktops** ready and removes desktops **nobody has used for 90 days**. Turn it on in the parameter file:

```bicep
param deployPoolAutomation = true
param spareDesktops = 5              // free (unassigned) desktops to keep ready
param deleteUnusedAfterDays = 90
param poolAutomationMode = 'Report'  // start with Report; switch to 'Apply' once happy
param maxDesktopsAddedPerRun = 10    // safety limits per daily run
param maxDesktopsDeletedPerRun = 5
```

Then run `Deploy-Avd.ps1 -InfraOnly`, or a normal deploy. The deployment creates an Automation account with a managed identity. It gets only:
- *Contributor* on the session host resource group;
- *Host Pool Contributor* and *Reader* on the service resource group;
- *Network Contributor* on the VNet;
- *Log Analytics Reader* on the workspace.

`Deploy-Avd.ps1` then runs [`Publish-AvdPoolAutomation.ps1`](scripts/Publish-AvdPoolAutomation.ps1). That publishes the runbook, its settings and the local admin password (as an encrypted Automation variable), the session host template spec, and a daily 06:30 UTC schedule.

**What it does each day** ([`infra/automation/Invoke-AvdPoolMaintenance.ps1`](infra/automation/Invoke-AvdPoolMaintenance.ps1)):
1. **Tracks usage.** It reads the last two days of AVD connections from Log Analytics and stamps each desktop VM with an `avd-last-used` tag. The 90-day clock lives on the VM, so it doesn't depend on Log Analytics retention. A desktop never connected to counts from its creation date. Tags are written in Report mode too, so tracking starts on day one.
2. **Tidies up.** Desktops idle for `deleteUnusedAfterDays` are deleted: removed from the host pool, then the VM with its NIC and disk. It never deletes:
   - a desktop with an active session;
   - a desktop tagged **`avd-keep = true`**;
   - a spare that's still needed to meet the spare target.

   It deletes at most `maxDesktopsDeletedPerRun` per run, most-idle first.
3. **Tops up spares.** If fewer than `spareDesktops` are unassigned, counting builds in progress, it deploys more. It uses the same session host template as the main deployment, so new desktops get the same image, profile settings and customisation. They're numbered after the highest existing desktop and spread across zones.

**Report first.** In `Report` mode the job lists what it would delete and add, and changes nothing apart from usage tags. Check the job output for a few days (*Automation account → Jobs*), or preview locally with your own login:

```powershell
.\infra\automation\Invoke-AvdPoolMaintenance.ps1 -ConfigPath .\infra\params\prod.automation.json
```

Then set `poolAutomationMode = 'Apply'` and run `Deploy-Avd.ps1 -InfraOnly` again.

**Things to know:**
- **Deleting a personal desktop deletes that user's local data** (profile on the VM). Tag anyone who must be kept with `avd-keep = true`, or keep FSLogix or OneDrive Known Folder Move for user data.
- **Entra device objects** of deleted desktops are listed in the job output but not deleted, because that needs a directory role, not just Azure RBAC. Clean them up periodically in *Entra ID → Devices*, which has a stale-device filter.
- **New desktops build in ~30–60 minutes.** The job counts them as "building" so it doesn't over-provision, and flags any that never register.
- **Password and settings:** change the local admin password or any setting by re-running `Deploy-Avd.ps1 -InfraOnly`. That republishes everything.
- **vCPU quota:** spares need quota too. With 5 spare D4s_v5 desktops that's 20 vCPU on top of your assigned desktops.

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

## If a deployment fails

**Fix the cause and re-run the same command. You don't need to start over.** Deployments are idempotent: anything that already succeeded is left as it is, and the run continues from where it stopped. `Deploy-Avd.ps1 -WhatIf` shows what's left to do.

To see why a run failed, find the deployment in the portal (*Subscription → Deployments*), or run:

```powershell
az deployment sub show --name <deployment name> --query properties.error
```

Common causes:

| Error | Cause | Fix |
|---|---|---|
| *"A virtual network cannot be linked to multiple zones with overlapping namespaces… privatelink.file.core.windows.net"* | The VNet is already linked to a `privatelink.file` zone: a central or hub zone, or a leftover from an earlier attempt that used a different storage resource group. `privateDnsZoneMode = 'new'` tries to link a second one. | Use the zone that's already linked: `privateDnsZoneMode = 'existing'` and `existingFilePrivateDnsZoneId = '<that zone's ID>'`. `Deploy-Avd.ps1` now checks for this before deploying and prints the ID. If the zone is a leftover from your own earlier attempt, you can delete its VNet link instead. |
| Quota / `OperationNotAllowed` on VMs | vCPU quota | Request more quota for the VM family and region, then re-run with `-AddHosts` for the missing hosts. |
| `AADLoginForWindows` exit code `-2145648607` | The host can't reach `enterpriseregistration.windows.net` | Firewall: see [`docs/firewall-rules.md`](docs/firewall-rules.md) |
| Extension error on a host that autoscale stopped | A re-run touched an existing, deallocated host | Use `-AddHosts` or `-InfraOnly` |

**Start over only if you want to change names** (prefix, environment, resource group names), because names can't be changed in place. In that case:
- Delete only the resource groups the deployment **created** (`create: true`), never your existing network or DNS groups.
- Delete stale device objects for the old hosts in **Entra ID → Devices**. A rebuilt `avdsh-001` creates a new device object, and the old one stays behind.
- If you renamed resource groups between attempts, resources from the first attempt are still in the old groups. That's the usual cause of the DNS error above.

## Firewall rules

No inbound rules are needed. If outbound traffic goes through a firewall (hub firewall mode, or an existing VNet behind one), allow the endpoints in [`docs/firewall-rules.md`](docs/firewall-rules.md) before the pilot. If the Entra join and agent endpoints are blocked, the host deployment fails.

## Post-deployment steps (required)

These steps can't be expressed in ARM/Bicep. Run them once after the first deployment that includes FSLogix storage. They apply to every host, current and future.

1. **Configure the storage account's Entra app.** This is required for profiles to load. Run it as an admin who can manage app registrations:
   ```powershell
   .\scripts\Set-FslogixStorageAuth.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf
   ```
   ```powershell
   .\scripts\Set-FslogixStorageAuth.ps1 -ParameterFile .\infra\params\prod.bicepparam
   ```
   Enabling Entra Kerberos creates an app called `[Storage Account] <name>.file.core.windows.net`. The script configures it to Microsoft's guidance:
   - **Private link names.** Hosts reach the share through the private endpoint, so DNS returns `<name>.privatelink.file.core.windows.net`. The app needs matching `privatelink` identifier URIs. Without them, Kerberos fails and the mount falls back to NTLM, which gives error **1326**.
   - **Cloud-only groups.** It adds the `kdc_enable_cloud_group_sids` tag so groups that exist only in Entra ID are included in the Kerberos ticket. This is required for cloud-only identities. Microsoft is moving this to a `kerberosTicket` optional claim (preview). The tag is what the Azure Files and FSLogix guides currently use.
   - **Admin consent** for the app (`openid`, `profile`, `User.Read`).
   - **Conditional Access check.** Entra Kerberos doesn't support MFA for the share. The script lists any enabled policy that requires MFA and covers this app. Exclude the app in each one, or mounts fail with error **1327**. The script only reads policies; it doesn't change them.
2. **Restart the session hosts** that were deployed before this step. New hosts restart automatically at the end of their build, because the Kerberos setting needs a restart.
3. **Optional: lock down NTFS permissions on the `profiles` share.** By default every authenticated identity has the *Storage File Data SMB Share Contributor* share role (`fslogixDefaultSharePermission`), as FSLogix guidance recommends. Folder permissions then control who sees what. For cloud-only identities, set them in the portal: *Storage account → File shares → profiles → Browse → Manage access*. File Explorer and icacls don't support cloud-only identities. Microsoft's FSLogix recommendation:
   - **CREATOR OWNER:** Modify, subfolders and files only
   - **Admins group:** Full control
   - **Users group:** Modify, this folder only
4. **Enable Entra SSO for the tenant.** This step is **required if any users are guests**. Members can skip it, but they then get an extra sign-in prompt:
   ```powershell
   .\scripts\Enable-EntraSSO.ps1 -SessionHostPrefix avdpd
   ```
   `-SessionHostPrefix` creates (or reuses) a **dynamic device group**, *AVD Session Hosts*, with the rule `(device.displayName -startsWith "avdpd-")`. Every session host joins it automatically, including ones added later. The script then trusts that group, which removes the *Allow remote desktop connection?* prompt.
   - **Several prefixes:** list them all, e.g. `-SessionHostPrefix avdsh, avdpd`.
   - **Dynamic groups need Entra ID P1.** Without it, create a normal security group, add the session host devices, and pass `-TargetDeviceGroupId <object ID>`.
   - **Finding an existing group's ID:** *Entra ID → Groups → the group → Overview → Object ID*, or run `az ad group show --group "AVD Session Hosts" --query id -o tsv`.
   - **Requirement:** the Microsoft Graph PowerShell modules (`Install-Module Microsoft.Graph -Scope CurrentUser`).
5. **Check a host:** run `.\scripts\Get-FslogixHostDiagnostics.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName avdsh-001`. See *Profiles fail to load at sign-in* below.

### Profiles fail to load at sign-in

Run the host diagnostics. They need no RDP and make no changes:

```powershell
.\scripts\Get-FslogixHostDiagnostics.ps1 -ParameterFile .\infra\params\prod.bicepparam -VmName avdsh-001
```

The report shows the registry settings, required services, DNS for the storage account (private or public IP), TCP 445, and the last FSLogix errors decoded with their likely fix:

| Code in FSLogix log | Meaning | Fix |
|---|---|---|
| **1326** (`0000052E`) | No Kerberos ticket, so it fell back to NTLM | `Set-FslogixStorageAuth.ps1` (privatelink names, consent), then restart the host |
| **1327** (`0000052F`) | Account restrictions | An MFA Conditional Access policy covers the storage app. Exclude it. |
| **5** (`00000005`) | Access denied | In order: **storage firewall** doesn't allow the host subnet (service endpoint mode, or a leftover rule); **share-level permission** missing or not applied yet (takes up to ~30 min); NTFS permissions changed from the defaults. The Azure-side section of `Get-FslogixHostDiagnostics.ps1` checks the first two. |
| **53 / 67** | Network path or name not found | DNS (the account must resolve to the private endpoint IP) or TCP 445 blocked |
| **1311** | No logon servers | Kerberos ticket retrieval isn't active: check the registry setting and restart |

**Testing as the affected user.** FSLogix blocks sign-in when the profile fails (`PreventLoginWithFailure`), so the user can't log on to see the real error. Exclude them from FSLogix on one host temporarily (Entra users use the `AzureAD\` prefix):

```powershell
az vm run-command invoke -g <hosts RG> -n avdsh-001 --command-id RunPowerShellScript --scripts 'net localgroup "FSLogix Profile Exclude List" "AzureAD\alice@contoso.com" /add'
```

They can then sign in with a local profile. In a command prompt, run:

```
klist get cifs/<storage account>.file.core.windows.net
```

```
dir \\<storage account>.file.core.windows.net\profiles
```

The first should return a ticket and the second should list the share. Any error here is the real one. Afterwards, sign them out and remove the exclusion with the same command, using `/delete` instead of `/add`.

**DNS:** `<name>.file.core.windows.net` must resolve, via a `privatelink` CNAME, to the private endpoint's IP **from the session host**.
- With `privateDnsZoneMode = 'new'`, the template links the zone to the VNet.
- With `'existing'`, the central zone must be linked to the VNet, or to the hub VNet if hosts use a hub DNS server or resolver, and that resolver must forward to Azure DNS.
- With `'policyManaged'`, check that the policy actually created the A record in the zone.

If DNS returns a public IP, the zone isn't being used. Public network access on the account is disabled, so that fails.

**Guests:** the Azure Files guide supports external users only for FSLogix on AVD. Entra's Kerberos overview says B2B guests can't currently use Entra Kerberos. The two pages conflict, so test a guest before relying on it.

### FSLogix without private endpoints (`fslogixNetworkAccess = 'serviceEndpoint'`)

Use this if you can't add private DNS records, for example when the DNS zone is owned by another team. There's no private endpoint and no `privatelink` zone:
- The storage account keeps its normal public name and IP, resolved by ordinary public DNS.
- The session host subnet gets a **Microsoft.Storage service endpoint**. Traffic to the account goes over the Microsoft backbone, not the internet.
- The storage firewall denies everything except that subnet.
- Authentication is unchanged: Entra Kerberos, with shared keys disabled.

| | Private endpoint (default) | Service endpoint |
|---|---|---|
| DNS changes | `privatelink.file` zone must resolve from the hosts | None |
| Storage public endpoint | Disabled | Enabled, firewalled to the host subnet only |
| Subnet change | — | Microsoft.Storage service endpoint on the host subnet |
| Reachable from on-premises / other VNets | Yes, via the private IP | No, only from the host subnet. FSLogix doesn't need more. |

**Switching an existing deployment:**
1. **Existing VNet only:** add the service endpoint to the session host subnet. `Deploy-Avd.ps1` checks this and prints the exact command, which keeps any endpoints the subnet already has:
   ```powershell
   az network vnet subnet update --ids <session host subnet ID> --service-endpoints Microsoft.Storage
   ```
   With a new VNet, the template adds it for you.
2. **Set the parameter and redeploy the shared resources:**
   ```bicep
   param fslogixNetworkAccess = 'serviceEndpoint'
   ```
   ```powershell
   .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -InfraOnly
   ```
3. **Delete the old private endpoint** `pe-<storage account>-file` (in the storage resource group). If `privateDnsZoneMode` was `new`, delete that zone too. Deployments don't delete resources, and while the endpoint exists the account's DNS still points at `privatelink`.
4. **Check a host:** run `Get-FslogixHostDiagnostics.ps1`. In this mode a **public** IP for the storage account is expected and reported as OK.

**Network notes:**
- **NSG:** if an NSG on the host subnet denies outbound internet, allow TCP 445 outbound to the `Storage.<region>` service tag.
- **Firewall:** a `0.0.0.0/0` route to a firewall doesn't catch this traffic. The service endpoint adds more specific routes for Azure Storage, so SMB goes direct and no firewall rule is needed.
- **Entra app:** `Set-FslogixStorageAuth.ps1` still applies. The privatelink names it adds do no harm once the endpoint is gone.

## Connecting

Users subscribe in Windows App or use the web client at `https://windows.cloud.microsoft`. Because the hosts are Entra-joined, the client device must be Entra joined or registered, or SSO (`enablerdsaadauth`) must be enabled, which is the default here.

### A user can't see the desktop in Windows App

Run the read-only access check for that user:

```powershell
.\scripts\Test-AvdUserAccess.ps1 -ParameterFile .\infra\params\prod.bicepparam -User alice@contoso.com
```

It checks each requirement in order and prints PASS / WARN / FAIL with the fix:
1. The account exists and is enabled, and whether it's a member or a guest. Guests can be given by email address.
2. **Desktop Virtualization User** on the app group (directly or through a group). This is what makes the desktop appear, and the script flags nested groups.
3. The app group is registered in the workspace.
4. **Virtual Machine User Login** on the hosts. Without it the desktop appears but sign-in is refused.
5. The session hosts are available and not draining.
6. SSO on the host pool and the tenant-wide Entra RDP setting.
7. Guest-specific requirements.

Then check the client side:
- **Try the web client first:** <https://windows.cloud.microsoft> in a private browser window. If the desktop appears there but not in Windows App, the app is signed in with a different account. On Windows it uses the account signed in to Windows, so add the correct work account, or sign out and back in.
- **After changing groups or assignments:** sign out of Windows App and back in. Membership changes take a few minutes, longer for dynamic groups.
- **Conditional Access:** Entra ID → Sign-in logs for the user, filtered to *Azure Virtual Desktop* and *Windows Cloud Login*.

### Guest (external) users

Microsoft supports guests on this design (*AVD authentication → External identity*), with these requirements:
- **Hosts:** Entra-joined (yes) and running Windows 11 24H2 or later with the 2025-09 cumulative update or later. The marketplace image with `version: 'latest'` meets this.
- **SSO:** set on the host pool (`enableSingleSignOn = true`, the default) **and** at tenant level (`Enable-EntraSSO.ps1`, post-deployment step 4).
- **Client:** Windows App on Windows, macOS, iOS or Android, or the web client.
- **Account type:** the guest signs in with an Entra work or school account or a Microsoft account. **Email one-time passcode guests are not supported.**
- **Licensing:** the guest needs an eligible licence, e.g. Microsoft 365 E3, assigned to their guest object **in this tenant**.
- **Profiles:** FSLogix on Azure Files authenticates with Entra Kerberos, and it isn't confirmed that guest accounts can get that ticket. With `PreventLoginWithFailure = 1`, a failed profile mount blocks sign-in. Test a guest on the pilot host before rolling out.

## Things you might want to change

| Parameter | Default | Notes |
|---|---|---|
| `loadBalancerType` | `BreadthFirst` | Use `DepthFirst` to pack hosts and maximise autoscale savings |
| `scalingPlanTimeZone` / schedule | GMT, 07:00–20:00 weekdays | Edit the schedule in `modules/hostpool.bicep` |
| `imageReference` | Win 11 24H2 multi-session + M365 | Swap in an Azure Compute Gallery image for production |
| `encryptionAtHost` | `false` | Requires `Microsoft.Compute/EncryptionAtHost` feature registration |
