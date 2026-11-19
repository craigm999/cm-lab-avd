# Firewall and network rules

This is what this deployment needs through your firewall or NSGs. It's based on Microsoft Learn *"Required FQDNs and endpoints for Azure Virtual Desktop"* (updated 2026-09-02), *"RDP Shortpath"* (2026-10-23) and *"Sign in to a Windows VM in Azure by using Microsoft Entra ID"*. Microsoft revises these lists, so re-check the AVD page before go-live: <https://learn.microsoft.com/azure/virtual-desktop/required-fqdn-endpoint>.

## Summary

| Direction | What | Needed? |
|---|---|---|
| **Inbound** to session hosts from the internet or users | Nothing | **No inbound rules.** AVD uses reverse connect: hosts open outbound 443 to the AVD service. Keep the internet blocked inbound. |
| **Outbound** from session hosts | AVD service, Entra ID, certificates, KMS, agent updates (tables below) | **Yes** if outbound passes through a firewall or proxy |
| **Internal**: hosts → storage private endpoint | TCP 445 | **Yes** if an NSG or NVA sits between the subnets |
| **Outbound** from user devices | AVD client endpoints | **Yes** if users are behind a corporate proxy or firewall |

If you choose **NAT gateway** in the questionnaire, outbound internet access is open and you only need the internal rule (already in the template's NSG). If you choose **hub firewall**, or deploy into an existing VNet whose traffic goes through a firewall, add everything below.

---

## 1. Session hosts → internet (outbound)

### Azure Firewall shortcut

Allow these from the session host subnet (e.g. `10.50.0.0/22`). They cover most of the list:

- **Application rule**, FQDN tag `WindowsVirtualDesktop`, HTTPS 443
- **Network rule**, service tags `WindowsVirtualDesktop`, `AzureActiveDirectory`, `AzureMonitor`, `AzureFrontDoor.Frontend`, TCP 443
- **Network rule**, `51.5.0.0/16`, UDP 3478 (RDP Shortpath relay)

Then add the remaining rows from the tables below as application rules. Microsoft recommends using **both** the service tags and the FQDN tag. It publishes no static IP list for AVD, so a third-party firewall needs FQDN rules or a dynamic Azure IP feed.

### Required: AVD service

| Address | Protocol / port | Purpose | Service tag |
|---|---|---|---|
| `login.microsoftonline.com` | TCP 443 | Authentication | `AzureActiveDirectory` |
| `*.wvd.microsoft.com` | TCP 443 | AVD service and reverse-connect traffic | `WindowsVirtualDesktop` |
| `*.service.windows.cloud.microsoft` | TCP 443 | Service traffic | `WindowsVirtualDesktop` |
| `*.windows.cloud.microsoft` | TCP 443 | Service traffic | — |
| `*.windows.static.microsoft` | TCP 443 | Service traffic | — |
| `51.5.0.0/16` | **UDP 3478** | RDP Shortpath relay (TURN) | `WindowsVirtualDesktop` |
| `catalogartifact.azureedge.net` | TCP 443 | Azure Marketplace | `AzureFrontDoor.Frontend` |
| `*.prod.warm.ingest.monitor.core.windows.net` | TCP 443 | Agent diagnostics | `AzureMonitor` |
| `gcs.prod.monitoring.core.windows.net` | TCP 443 | Agent traffic | `AzureMonitor` |
| `mrsglobalsteus2prod.blob.core.windows.net` | TCP 443 | AVD agent and stack updates | `Storage` |
| `wvdportalstorageblob.blob.core.windows.net` | TCP 443 | **Agent install package used by this deployment's DSC step** | `AzureCloud` |
| `azkms.core.windows.net` | **TCP 1688** | Windows activation | — |
| `oneocsp.microsoft.com` | **TCP 80** | Certificates | `AzureFrontDoor.FirstParty` |
| `www.microsoft.com` | TCP 80 | Certificates | — |
| `*.aikcertaia.microsoft.com` | TCP 80 | Certificates | — |
| `azcsprodeusaikpublish.blob.core.windows.net` | TCP 80 | Certificates | — |
| `*.microsoftaik.azure.net` | TCP 80 | Certificates | — |
| `ctldl.windowsupdate.com` | TCP 80 | Certificates | — |

Several required entries are **plain HTTP on port 80** (certificate checks). Firewalls that only allow 443 commonly miss these.

### Required: Entra join (the AADLoginForWindows extension)

| Address | Protocol / port | Purpose |
|---|---|---|
| `enterpriseregistration.windows.net` | TCP 443 | Device registration (Entra join) |
| `login.microsoftonline.com` | TCP 443 | Authentication (already listed above) |
| `pas.windows.net` | TCP 443 | Entra RBAC check at sign-in (Virtual Machine User Login) |
| `device.login.microsoftonline.com` | TCP 443 | Device authentication. Listed in Microsoft's troubleshooting checks. |

If `enterpriseregistration.windows.net` is blocked, the Entra join step fails with exit code `-2145648607` and the deployment stops at that host.

### Never route through a firewall: Azure platform addresses

| Address | Port | Purpose |
|---|---|---|
| `169.254.169.254` | TCP 80 | Instance Metadata Service. Entra join reads the tenant ID from it. |
| `168.63.129.16` | TCP 80, TCP 32526, TCP/UDP 53 | Azure platform: VM agent, extensions, Azure DNS |

These are handled by the Azure host and aren't affected by the template's `0.0.0.0/0` route. Don't add NSG rules that deny them, and don't proxy them.

### Recommended (optional in Microsoft's list, but expect to need them)

| Address | Port | Purpose |
|---|---|---|
| `login.windows.net` | TCP 443 | Microsoft 365 sign-in |
| `*.events.data.microsoft.com` | TCP 443 | Telemetry |
| `www.msftconnecttest.com` | TCP 80 | Windows connectivity check. Without it, apps may report "no internet". |
| `*.prod.do.dsp.mp.microsoft.com` | TCP 443 | Windows Update delivery |
| `*.sfx.ms` | TCP 443 | OneDrive client updates |
| `*.digicert.com` | TCP 80 | Certificate revocation |
| Windows Update, Microsoft Defender, Microsoft 365 Apps / Teams / OneDrive | various | Use Microsoft's published Microsoft 365 endpoint list and the `WindowsUpdate` FQDN tag. The image includes Microsoft 365 Apps. |
| Trusted Launch guest attestation | TCP 443 | The `GuestAttestation` extension reports boot integrity to Microsoft Azure Attestation. The Microsoft pages I checked don't list its endpoints. Allowing the `AzureAttestation` service tag is the usual approach. If it's blocked, sign-in still works but Defender for Cloud raises boot-integrity alerts. |

### RDP Shortpath (UDP) for better session quality

This is optional: without UDP, sessions fall back to TCP 443. With UDP they're noticeably better for latency and media.

| From | To | Port | Purpose |
|---|---|---|---|
| Session host subnet | `51.5.0.0/16` | UDP 3478 | STUN/TURN relay (also in the required list) |
| Session host subnet | Any | UDP 49152–65535 | STUN direct connection |

NAT gateway and Azure Firewall both use symmetric NAT, so direct STUN usually won't work through them and sessions use the **TURN relay** (`51.5.0.0/16`, UDP 3478). Allowing that one rule gets you UDP. Microsoft also advises against packet inspection and force-tunnelling for this traffic.

### TLS inspection

Don't apply TLS break-and-inspect to AVD traffic (`*.wvd.microsoft.com`, `*.windows.cloud.microsoft`, `51.5.0.0/16`), Entra endpoints, or the certificate endpoints. AVD uses its own certificates for connection encryption and doesn't support re-signed certificates there. Inspection also breaks or degrades RDP Shortpath.

---

## 2. Internal traffic inside your network

| From | To | Port | Notes |
|---|---|---|---|
| Session host subnet | Storage private endpoint (PE subnet) | **TCP 445** (SMB) | FSLogix profiles. The template's PE subnet NSG allows this for a new VNet. In an existing VNet, add it yourself. If traffic between subnets goes through an NVA, allow it there too. |
| Session host subnet | Your DNS servers / Private DNS Resolver | TCP/UDP 53 | Only if you use custom DNS. The hosts must resolve `<storage>.file.core.windows.net` to the **private endpoint IP**. |

Azure Files authentication uses Entra Kerberos. Hosts get the Kerberos ticket from `login.microsoftonline.com`, which is already allowed above. No domain controller ports are needed.

## 3. User devices → AVD (outbound from your offices or proxy)

Users connecting through a corporate proxy or firewall need:

| Address | Port | Purpose |
|---|---|---|
| `*.wvd.microsoft.com` | TCP 443 | Service traffic |
| `*.service.windows.cloud.microsoft` | TCP 443 | Service traffic |
| `*.windows.cloud.microsoft`, `windows.cloud.microsoft` | TCP 443 | Service traffic, Windows App / web client |
| `*.windows.static.microsoft` | TCP 443 | Service traffic |
| `login.microsoftonline.com`, `graph.microsoft.com` | TCP 443 | Sign-in, SSO |
| `windows365.microsoft.com`, `ecs.office.com` | TCP 443 | Connection center |
| `*.servicebus.windows.net` | TCP 443 | Troubleshooting data |
| `go.microsoft.com`, `aka.ms`, `learn.microsoft.com`, `privacy.microsoft.com` | TCP 443 | Client links |
| `*.cdn.office.net` | TCP 443 | Client updates (Windows desktop client) |
| `*.events.data.microsoft.com` | TCP 443 | Client telemetry |
| `www.microsoft.com`, `*.microsoftaik.azure.net`, `*.aikcertaia.microsoft.com`, `azcsprodeusaikpublish.blob.core.windows.net` | TCP 80 | Certificates |
| `51.5.0.0/16` | UDP 3478 | RDP Shortpath relay (optional, improves quality) |

## Pre-go-live check from the pilot host

From `avdsh-001`, in PowerShell as admin:

```powershell
$hosts443 = 'login.microsoftonline.com', 'enterpriseregistration.windows.net', 'pas.windows.net',
            'rdbroker.wvd.microsoft.com', 'catalogartifact.azureedge.net',
            'mrsglobalsteus2prod.blob.core.windows.net', 'wvdportalstorageblob.blob.core.windows.net'
foreach ($h in $hosts443) {
    '{0,-45} 443  {1}' -f $h, (Test-NetConnection $h -Port 443 -InformationLevel Quiet)
}
'{0,-45} 1688 {1}' -f 'azkms.core.windows.net', (Test-NetConnection azkms.core.windows.net -Port 1688 -InformationLevel Quiet)
'{0,-45} 80   {1}' -f 'oneocsp.microsoft.com', (Test-NetConnection oneocsp.microsoft.com -Port 80 -InformationLevel Quiet)

Resolve-DnsName <storageaccount>.file.core.windows.net    # must return the private endpoint IP
Test-NetConnection <storageaccount>.file.core.windows.net -Port 445
```

The AVD agent also includes a URL check tool:

```powershell
& (Get-ChildItem 'C:\Program Files\Microsoft RDInfra\RDAgent_*\WVDAgentUrlTool.exe' | Select-Object -Last 1).FullName
```

It lists any required AVD URL the host can't reach.
