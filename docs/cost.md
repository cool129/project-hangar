# Cost

Estimates use Azure pay-as-you-go **list prices for East US 2**, approximate, before tax and
excluding free grants. **Check them with the
[Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) before you
apply**: prices change, and some SKUs vary by region.

## Dev (designed to be created, demoed and destroyed)

| Resource | SKU | ≈ $/hour | ≈ $/month (24×7) |
|----------|-----|---------:|-----------------:|
| AKS control plane | Free tier | 0.00 | 0 |
| AKS nodes | 1 × Standard_B2ms (autoscales to 3) | 0.08 | 60 |
| PostgreSQL Flexible Server | B_Standard_B1ms + 32 GB | 0.02 | 17 |
| Legacy VM | Standard_B1ms + 30 GB StandardSSD | 0.02 | 18 |
| Load balancer + 2 public IPs | Standard | 0.03 | 25 |
| Container Registry | Basic | 0.01 | 5 |
| Log Analytics | ~0.2 GB/day ingestion (1 GB/day cap) | ~0.02 | ~15 |
| Key Vault, state storage, alerts | | <0.01 | ~3 |
| **Total** | | **≈ 0.18** | **≈ 140** |

**A full demo session** (apply ~20 min, demo ~1 h, destroy ~15 min) costs **under $1**.
Destroy when you're done: `make infra-destroy ENV=dev`.

## Prod (production-like; stand up for demos only)

| Resource | SKU | ≈ $/hour |
|----------|-----|---------:|
| AKS control plane | Standard tier (uptime SLA) | 0.10 |
| AKS nodes | 2 × Standard_D2s_v5 (scales to 5) | 0.19 |
| PostgreSQL | GP_Standard_D2ds_v5, zone-redundant HA (2 × compute) | 0.36 |
| Legacy VM, LB, ACR Standard, logs, vault | | 0.08 |
| **Total** | | **≈ 0.73/hour (≈ $530/month)** |

## Where the money goes and the levers

| Lever | Saving | Trade-off |
|-------|--------|-----------|
| Destroy dev outside working hours | ~70% of dev | Rebuild takes about 20 minutes (fully automated) |
| `az postgres flexible-server stop` overnight | Compute only (storage still billed); auto-restarts after 7 days | Manual start |
| AKS start/stop (`az aks stop`) | Node + LB cost | Cluster unavailable |
| Log Analytics daily cap (dev: 1 GB/day) | Bounds runaway ingestion | Logs dropped past the cap |
| B-series burstable nodes in dev | ~40% vs D-series | CPU credits can run out under sustained load |
| Reserved instances / savings plan (prod) | 30 to 60% | 1 or 3-year commitment |

## Built-in guardrails

- Every resource is tagged `project`, `environment`, `cost-center` (Terraform root inputs),
  so Cost Management can group by environment.
- Dev Key Vault has purge protection off, so `infra-destroy` leaves nothing billable behind.
- The **local stack costs $0** and covers most of the engineering: compose, kind e2e,
  migration rehearsal and chaos drills all run on a laptop.
