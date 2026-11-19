# AVD deployment questionnaire

Fill this in before you deploy. You can either:

- **Run the interactive version:** `pwsh ./scripts/New-AvdParameterFile.ps1`. It asks these same questions, checks the answers against Azure when you're signed in with `az`, and writes `infra/params/<env>.bicepparam`.
- **Fill in this document** (for example, send it to the customer), then enter the answers into the script or straight into a copy of `infra/main.bicepparam`.

The **Parameter** column shows the parameter in `main.bicep` that each answer sets. **N/E** means *New* (the deployment creates it) or *Existing* (it's already there and the deployment only uses it).

---

## 1. Tenant and subscriptions

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 1.1 | Entra ID tenant ID | | Used by `az login --tenant` |
| 1.2 | **Workload subscription ID**, where the session hosts, host pool and storage go | | Deployment target |
| 1.3 | Is the session host VNet in this same subscription? | Yes / No | **Must be Yes.** Azure requires a NIC and its VNet to be in the same subscription. If the VNet is elsewhere, deploy into *that* subscription. |
| 1.4 | Hub / connectivity subscription ID, if you have one | | Hub peering, central private DNS |
| 1.5 | Management subscription ID, if Log Analytics is central | | Existing workspace |

## 2. Region and naming

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 2.1 | Azure region (e.g. `uksouth`) | | `location`. Must match the region of an existing VNet. |
| 2.2 | Workload short name, max 8 characters | `avd` | `workloadName` |
| 2.3 | Environment name, max 6 characters (prod, dev, ...) | `prod` | `environmentName` |
| 2.4 | Session host name prefix, max 10 characters. Hosts are named `<prefix>-001` to `<prefix>-100` | `avdsh` | `sessionHostNamePrefix`. Check these names don't clash with existing machines in Entra ID. |
| 2.5 | Mandatory tags (owner, cost centre, ...) | | `tags` |

## 3. Resource groups

Leave the name blank to use the default convention, `rg-<workload>-<env>-<region>-<role>`. Several components can share one resource group.

| # | Component | Resource group name | N/E | Notes |
|---|---|---|---|---|
| 3.1 | AVD service objects: host pool, app group, workspace, scaling plan | | N / E | `resourceGroups.service` |
| 3.2 | Session host VMs, NICs and disks | | N / E | `resourceGroups.hosts`. A dedicated resource group is recommended, because the VM login roles are granted on it. |
| 3.3 | FSLogix storage and private endpoint | | N / E | `resourceGroups.storage` |
| 3.4 | Network. Only needed if section 4 is *New VNet* | | N / E | `resourceGroups.network` |
| 3.5 | Log Analytics. Only needed if section 7 is *New* | | N / E | `resourceGroups.monitor` |

> If you mark an existing resource group as **New**, the deployment updates it and **replaces its tags**. Mark existing resource groups as **E**.

## 4. Networking

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 4.1 | Use an **existing** VNet or create a **new** one? | Existing / New | `networkMode` |

### 4A. Existing VNet

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 4A.1 | VNet name and resource group | | |
| 4A.2 | Session host subnet name and resource ID | | `existingSessionHostSubnetId`. It needs **at least 100 free IPs**; a /24 is the practical minimum and a /23 leaves room to grow. |
| 4A.3 | Private endpoint subnet name and resource ID. Can be the same subnet | | `existingPrivateEndpointSubnetId` |
| 4A.4 | How do hosts reach the internet? (Firewall/UDR, NAT gateway, other) | | It must be in place already. See 4.6. |
| 4A.5 | DNS servers configured on the VNet | | They must be able to resolve `privatelink.file.core.windows.net` |

### 4B. New VNet

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 4B.1 | VNet name, or leave blank for the default | | `vnetName` |
| 4B.2 | VNet address space, which must not overlap hub, on-premises or other spokes | `10.50.0.0/16` | `vnetAddressPrefix` |
| 4B.3 | Session host subnet, /23 or larger recommended | `10.50.0.0/22` | `sessionHostSubnetPrefix` |
| 4B.4 | Private endpoint subnet | `10.50.4.0/27` | `privateEndpointSubnetPrefix` |
| 4B.5 | Custom DNS server IPs (hub DNS resolver or firewall), or blank for Azure DNS | | `dnsServers` |
| 4B.6 | Outbound internet method: NAT gateway / route to hub firewall / none (you provide it) | NAT gateway | `outboundMethod` |
| 4B.7 | Hub firewall private IP, if routing to the firewall | | `firewallPrivateIp` |
| 4B.8 | Peer to a hub VNet? Give the hub VNet resource ID | | `hubVnetId`. The deploying identity needs Network Contributor on the hub VNet. |
| 4B.9 | Use the hub's VPN/ExpressRoute gateway? | Yes / No | `hubUseRemoteGateways` |

### 4.6 Firewall rules

No **inbound** rules are needed: AVD uses reverse connect. If outbound traffic goes through a firewall or proxy, the full list is in [`firewall-rules.md`](firewall-rules.md). These are the items most often missed:

- **TCP 443:**
  - `*.wvd.microsoft.com`
  - `*.windows.cloud.microsoft`
  - `login.microsoftonline.com`
  - `enterpriseregistration.windows.net`
  - `pas.windows.net`
  - `wvdportalstorageblob.blob.core.windows.net`
  - `mrsglobalsteus2prod.blob.core.windows.net`
- **TCP 80**, for certificate checks: `oneocsp.microsoft.com`, `www.microsoft.com`, `ctldl.windowsupdate.com`, `*.microsoftaik.azure.net`
- **TCP 1688:** `azkms.core.windows.net`
- **UDP 3478:** `51.5.0.0/16` (RDP Shortpath, recommended)
- **TCP 445** from the session host subnet to the storage private endpoint
- **No TLS inspection** on AVD or Entra traffic

| # | Question | Answer |
|---|---|---|
| 4.6.1 | Firewall product and who manages the rules | |
| 4.6.2 | Is TLS inspection in use? Can AVD and Entra traffic be excluded? | |
| 4.6.3 | Is UDP 3478 to `51.5.0.0/16` allowed (RDP Shortpath)? | |
| 4.6.4 | Do user devices go through a proxy? Are the client endpoints allowed? | |

## 5. Identity and access

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 5.1 | Entra ID group of **AVD users**: name and object ID | | `avdUsersGroupObjectId`. Gets *Desktop Virtualization User*, *Virtual Machine User Login* and the SMB share role. |
| 5.2 | Entra ID group of **AVD admins**: name and object ID (optional) | | `avdAdminsGroupObjectId`. Gets *Virtual Machine Administrator Login* and SMB Elevated Contributor. |
| 5.3 | Are users **hybrid** (synced from AD) or **cloud-only**? | Hybrid / Cloud-only | Affects FSLogix with Entra Kerberos. See the README. |
| 5.4 | Enable Entra single sign-on? | Yes | `enableSingleSignOn` |
| 5.5 | Which Conditional Access policies apply to AVD users? Is MFA required? | | The storage account app must be excluded from MFA policies |
| 5.6 | Local break-glass admin username | `avdadmin` | `localAdminUsername`. The password is supplied at deploy time and is not recorded here. |
| 5.7 | Who deploys, and with what role? | | Needs Owner, or Contributor plus User Access Administrator, on the workload subscription |

## 6. Session hosts and capacity

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 6.0 | Desktop type: **Pooled** (shared multi-session) or **Personal** (1:1, one VM per user) | Pooled | `hostPoolType`. Personal multiplies the VM count and quota: 1,000 users = 1,000 VMs. |
| 6.0a | *(Personal)* Assignment: **Automatic** (on first connection) or **Direct** (admin assigns) | Automatic | `personalAssignmentType` |
| 6.1 | Users to support (Pooled: concurrent users; Personal: one desktop each) | `1000` | `targetUserCount` |
| 6.2 | Users per host | `10` | `maxSessionsPerHost`, which gives 100 hosts |
| 6.3 | Typical workload: light / medium / heavy / graphics | | Drives `vmSize` |
| 6.4 | VM size | `Standard_D8s_v5` | `vmSize`. 100 hosts × 8 vCPU = **800 vCPU of quota** |
| 6.5 | Has the vCPU quota been approved in the region? | Yes / No | |
| 6.6 | Image: Marketplace (Win 11 multi-session + M365) or a Compute Gallery image ID | Marketplace | `imageReference` |
| 6.7 | Availability zones | 1, 2, 3 | `availabilityZones` |
| 6.8 | Initial rollout: all hosts, or a pilot of N first? | | `sessionHostCountOverride` |
| 6.9 | Is the EncryptionAtHost feature registered on the subscription? | Yes / No | `encryptionAtHost` |

## 7. Monitoring

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 7.1 | Log Analytics: **existing** workspace or **new**? | Existing / New | `logAnalyticsMode` |
| 7.2 | Existing workspace resource ID | | `existingLogAnalyticsWorkspaceId`. It can be in another subscription. |
| 7.3 | New workspace retention, in days | `30` | `logAnalyticsRetentionDays` |

## 8. User profiles (FSLogix)

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 8.1 | Deploy FSLogix storage? | Yes | `deployFslogixStorage` |
| 8.2 | Profile size cap per user, in MB | `30000` | `fslogixProfileSizeMB` |
| 8.3 | Share size, in GiB. Premium IOPS scale with size | `10240` | `fslogixShareQuotaGiB` |
| 8.4 | Redundancy: ZRS (zone-redundant) or LRS | ZRS | `fslogixStorageSku` |
| 8.4a | How do hosts reach the share? **Private endpoint** (needs the `privatelink.file` DNS zone) or **service endpoint** (no DNS changes; public endpoint firewalled to the host subnet) | Private endpoint | `fslogixNetworkAccess`. Choose service endpoint if you can't change DNS. |
| 8.5 | *(private endpoint only)* `privatelink.file.core.windows.net` DNS zone: **new**, **existing** (give its ID), or **managed by Azure Policy** | | `privateDnsZoneMode` / `existingFilePrivateDnsZoneId`. An existing zone must already be linked to the VNet, or to the hub that provides DNS. |

## 9. Host pool and scaling

| # | Question | Answer | Parameter / notes |
|---|---|---|---|
| 9.1 | Desktop name shown to users | `Corporate Desktop` | `desktopFriendlyName` |
| 9.2 | Load balancing: breadth-first (performance) or depth-first (cost) | Breadth-first | `loadBalancerType` |
| 9.3 | Deploy an autoscale plan? | Yes | `deployScalingPlan` |
| 9.4 | Time zone for the schedule (Windows ID) | `GMT Standard Time` | `scalingPlanTimeZone` |
| 9.5 | Business hours, and any weekend use | Weekdays 07:00–20:00 | Edit the schedules in `modules/hostpool.bicep` |

## 10. Sign-off checklist

- [ ] vCPU quota approved (6.5)
- [ ] VNet and subnets confirmed in the workload subscription and region (1.3, 4A)
- [ ] Outbound endpoints open on the firewall (4.6)
- [ ] Private endpoint mode: DNS can resolve `privatelink.file.core.windows.net` (4A.5 / 8.5). Service endpoint mode: the host subnet has, or may be given, the Microsoft.Storage service endpoint (8.4a).
- [ ] User and admin groups created (5.1, 5.2)
- [ ] Deployer has the required roles (5.7). Includes the hub VNet if peering (4B.8).
- [ ] Owner identified for the post-deployment steps: storage admin consent, CA exclusion, NTFS ACLs
