# Challenges Faced During Implementation & Deployment

Getting the app and Helm chart working was the easy part. Actually provisioning
the Azure infrastructure on a Free Trial subscription turned into its own
round of debugging, mostly region/quota restrictions that only show up once
you try to apply. Keeping the real errors here since they're useful evidence
of what "production readiness" actually runs into.

**ACR rejected in westeurope.** First attempt at creating the container
registry there came back with a flat 403:

```
RequestDisallowedByAzure: Resource 'citypopdevacrkzyqc' was disallowed by Azure:
The selected region is currently not accepting new customers.
```

Nothing was wrong with the Terraform config, the region itself was closed to
new customers on this subscription. Moved the primary region to `eastus` and
re-ran.

**Geo-replication target didn't support zone redundancy.** With
`zone_redundancy_enabled = true` on the registry, replicating to `westus`
failed:

```
ZoneRedundancyNotSupported: Zone redundancy is not supported for the selected
location westus.
```

`westus` doesn't have Availability Zones at all. Switched the replication
target to `northeurope`, which does.

**VM size not allowed, then not compatible with Ephemeral OS.** The first AKS
node pool used `Standard_D2s_v5`:

```
The VM size of Standard_D2s_v5 is not allowed in your subscription in
location 'eastus'.
```

Only v6/v7 series are permitted on this subscription, so I bumped it to
`Standard_D2s_v7` - which then failed for a different reason:

```
VMSizeDoesNotSupportEphemeralOS: The Virtual Machine size Standard_D2s_v7
does not support Ephemeral OS disk.
```

The plain "s" v7 SKUs don't carry the local temp disk that Ephemeral OS
needs; the "ds" variant does. Settled on `Standard_D2ds_v7`, with an
explicit, smaller `os_disk_size_gb` since the AKS default of 128GB is bigger
than that SKU's cache disk.

**Regional vCPU quota, separate from the SKU problem.** Even after fixing the
size, the user node pool still failed to create:

```
ErrCode_InsufficientVCPUQuota: Insufficient regional vcpu quota left for
location eastus. left regional vcpu quota 0, requested quota 8.
```

This subscription is capped at 4 total vCPUs per region, and being a Free
Trial, it isn't eligible for a self-service quota increase at all. Rather
than fight it, I redesigned the topology to fit inside the cap: one system
node and one user node, both `Standard_D2ds_v7` (2 vCPUs each), with no
autoscaling headroom left above that until the subscription is upgraded.

**GitHub's OIDC subject format changed under the federated credential.** CI
logins started failing partway through with:

```
AADSTS700213: No matching federated identity record found for presented
assertion subject 'repo:sagary2j@15179979/city-population-ak8s@1313745460:
environment:dev'.
```

GitHub had switched to embedding numeric owner/repo IDs into the subject
claim (`repo:OWNER@OWNER_ID/REPO@REPO_ID:...`) instead of the plain
`owner/repo` format the federated credential was originally set up with.
Pulled the numeric IDs out of the failing token and the GitHub API, then
rebuilt the federated credential subjects in `terraform/identity.tf` to
match the new format.
