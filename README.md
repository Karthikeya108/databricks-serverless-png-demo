# Databricks Serverless + Private Network Gateway demo (AWS)

**Databricks Unity Gateway + Private Network Gateway (PNG) on AWS.** A Databricks App and agents running on
**serverless compute** call internal MCP servers, REST APIs and databases **on behalf of the signed-in user**. The
lakehouse data sits in customer-owned S3, reached over Private Link. Both private paths come from **one network
connectivity configuration (NCC)**.

| Path | NCC feature | Used for |
|---|---|---|
| Serverless → S3 | Private endpoint rule (Private Link) | Delta tables in the catalog's **managed location** in a customer bucket with a deny-all bucket policy |
| Serverless → corporate network | **Private network gateway** (ENIs in a customer subnet) | Internal MCP servers, REST APIs and Postgres behind an internal ALB, in a hub-and-spoke network with optional AWS Network Firewall inspection |

Identity is **Microsoft Entra ID + OAuth end to end**. Users sign in to Databricks with Entra, the app uses **user
authorization**, and Unity Gateway calls the internal services with the **user's own Entra token** (per-user OAuth
connections). The services authorise each call per user.

```
 Databricks App (user authorization)
   ├─ Genie ── serverless SQL ── NCC private endpoint ──────────────► S3 (deny-all bucket policy) ── Delta tables
   └─ Unity Gateway MCP services (per-user OAuth, the user's Entra token)
          └─ serverless ── NCC private network gateway ──► dbx-connect VPC ── Transit Gateway
                                                              ├─(optional) inspection VPC: AWS Network Firewall
                                                              └─► internal-services VPC: internal ALB (TLS)
                                                                    ├─ servicedesk / assets   (MCP, Entra)
                                                                    ├─ orders / legacy        (REST APIs)
                                                                    └─ Postgres (RDS)
```

## Who creates what (private network gateway)

The customer creates the subnet and hands its ID to Databricks; Databricks only places the gateway's network
interfaces in it. The network team keeps routes, firewall, DNS and security group, and can revoke access by removing
the role.

| Component | Created by | In this repository |
|---|---|---|
| VPC for the Databricks landing zone (`dbx-connect`) | Customer | `infra/20-aws-network` |
| **Gateway subnet** (/28, dedicated to the gateway) | **Customer** | `infra/20-aws-network/vpcs.tf` |
| Security group for the gateway's network interfaces | Customer | `infra/20-aws-network` (`pngdemo-png-sg`) |
| Cross-account IAM role (manage network interfaces in this VPC only) | Customer | `infra/40-databricks-network` (`pngdemo-png-role`) |
| Routes, Transit Gateway, firewall, private DNS zone | Customer | `infra/20-aws-network` |
| Gateway object (subnet ID, security group ID, role ARN, destinations) | Customer, via the Databricks account API / Terraform | `infra/40-databricks-network` |
| **Network interfaces in the gateway subnet** | **Databricks**, through the role | tagged `Vendor = Databricks`; owned by the customer account, with the customer's security group |

## Repository layout

| Path | Contents |
|---|---|
| `services.yaml` | Registry of internal services, databases and egress allowlists. Firewall rules, connections and checks are generated from it |
| `infra/10-databricks-workspace` | Serverless workspace, metastore, account groups and workspace assignments |
| `infra/20-aws-network` | Hub and spoke: dbx-connect, inspection, internal-services and egress VPCs, Transit Gateway, Network Firewall (off by default), private DNS |
| `infra/21-network-smoke-test` | Reusable smoke test with real traffic from the gateway subnet |
| `infra/25-certificate` | Public wildcard certificate (Let's Encrypt via DNS-01) imported into ACM |
| `infra/30-aws-services` | Image build (CodeBuild), ECS Fargate services, internal ALB, RDS Postgres, database seeding function |
| `infra/35-aws-data` | Data bucket and access logging |
| `infra/40-databricks-network` | NCC, S3 private endpoint rule + bucket policy, private network gateway + cross-account role, workspace binding |
| `infra/45-databricks-egress` | Serverless network policy (egress control) attached to the workspace: `off`, `dry_run` or `enforced`, allowlist from `services.yaml` |
| `infra/50-databricks-uc` | Storage credential, external location, catalog, schemas, grants, serverless SQL warehouse |
| `infra/60-observability` | CloudWatch dashboard and saved Logs Insights queries: evidence that serverless traffic arrives through the gateway, per user |
| `services/` | MCP servers and REST APIs (one image, selected by `SERVER=`), Entra token validation |
| `bundle/` | Databricks Asset Bundle: data, connectivity and egress-check jobs, demo notebooks, MCP services, the Operations Assistant app, Genie space definition |
| `scripts/` | Entra app setup, UC connections, Genie space, Postgres federation, firewall toggle, pre-demo check, live traffic view |

## Prerequisites

- **Databricks:** a Databricks account on AWS with the private network gateway enabled, and account admin rights.
  Databricks CLI with OAuth profiles (no PATs): one for the account, one for the workspace.
- **AWS:** permissions for VPC, Transit Gateway, Network Firewall, ECS, ELB, RDS, S3, ACM, Route 53 private zones,
  CodeBuild/ECR and IAM roles. AWS CLI with an SSO profile.
- **Entra ID:** permission to create app registrations (no admin consent or Graph application permissions needed).
- **DNS:** a domain for the internal services with a public DNS-01 challenge. The demo uses a free DuckDNS name with a
  split-horizon Route 53 private zone. Set `domain` in `services.yaml` to your own name.
- Terraform ≥ 1.6, `jq`, Python 3.12, Azure CLI (`az`). No local Docker is needed.

## Configuration

Copy each `terraform.tfvars.example` to `terraform.tfvars` and `bundle/variable-overrides.json.example` to
`bundle/.databricks/bundle/dev/variable-overrides.json`, then fill in your values. All of these files are git-ignored.
Optional environment variables:

| Variable | Used by | Purpose |
|---|---|---|
| `DUCKDNS_TOKEN` | `infra/25-certificate` | DNS-01 challenge (keep it in a `chmod 600` env file, load it for the apply only) |
| `PIP_INDEX_URL` | `scripts/build-image.sh` | Python package index or corporate mirror (default: pypi.org) |
| `AWS_PROFILE`, `DATABRICKS_CONFIG_PROFILE` | scripts | CLI profiles (defaults: `pngdemo-sandbox`, `pngdemo-ws`) |

## Deployment

Run each stack with `terraform -chdir=infra/<stack> init && terraform -chdir=infra/<stack> apply`.

1. `infra/10-databricks-workspace`: workspace, metastore and account groups. Create the workspace CLI profile.
2. `infra/20-aws-network`: network, with the firewall off.
3. `infra/25-certificate`: `(set -a; . <your duckdns env file>; set +a; terraform -chdir=infra/25-certificate apply)`
4. `./scripts/01-entra-apps.sh`, then `./scripts/02-entra-obo.sh`: Entra apps, scope, role and redirect URI.
5. `infra/30-aws-services`: image build, services, ALB, Postgres.
6. `infra/35-aws-data`: data bucket.
7. `infra/40-databricks-network`: apply once, then apply again with `s3_rule_enabled = true` (bucket policy +
   enabled endpoint rule). Gateway provisioning takes about 5 minutes.
8. `infra/50-databricks-uc`: Unity Catalog objects and the SQL warehouse.
9. `./scripts/04-create-connections.sh`: one UC connection per service (per-user OAuth for Entra-protected services).
10. Bundle: `cd bundle && databricks bundle deploy`, then `databricks bundle run generate_ops_data`.
11. `./scripts/05-create-genie-space.sh`, put the space ID in the variable overrides, then
    `databricks bundle deploy && databricks bundle run ops_assistant`.
12. Each user signs in once per MCP service (Unity Gateway → MCPs, or on the connection page).

13. `./scripts/07-postgres-federation.sh`: seeds the inventory database (on the AWS side) and creates the read-only
    connection and the foreign catalog `ops_inventory`.
14. Optional: `infra/45-databricks-egress` (network policy). Apply it ahead of the demo, then run
    `./scripts/verify.sh --restart-warehouse`.

Check connectivity with `databricks bundle run connectivity_check` (all services through the gateway).

Optional: `infra/60-observability` adds the evidence dashboard and saved queries (apply after `30`).

## Operating the demo

- **Pre-demo check:** `./scripts/verify.sh` checks logins, network, gateway, policy, credentials, app, warehouse and
  Postgres, and warms up the MCP services. Run it about 30 minutes before the demo.
- **Notebooks** (bundle, `notebooks/`): `act6_beyond_mcp` (REST API from SQL, Postgres via federation, join with the
  lakehouse), `act7_route_is_not_permission` (direct calls without a token; firewall `per_service` mode),
  `act8_egress_controls` (side-by-side comparison of egress setups and the denial log).
- **Egress check:** `databricks bundle run egress_check --params label="<setup>"` records which destinations are
  reachable from serverless, and with which source IP, in `ops_demo.lakehouse.egress_checks`.

- **Firewall:** `./scripts/firewall.sh on|off|per-service|network|status`. It's off by default to save cost; switch it on the day before
  the demo.
- **Show that traffic comes through the gateway:**
  - Dashboard `pngdemo-private-network-gateway` (URL: `terraform -chdir=infra/60-observability output dashboard_url`):
    calls by user and source IP, gateway subnet → services (VPC flow logs), firewall verdicts, rejected connections
    and requests per service.
  - Saved queries in CloudWatch Logs Insights, folder `pngdemo`, for the same views.
  - Gateway configuration as Databricks has it (state, mode, destinations, subnet, security group, role):
    `./scripts/show-gateway.sh`.
  - Terminal: `./scripts/show-traffic.sh enis` (the gateway's network interfaces in your subnet) and
    `./scripts/show-traffic.sh all` (calls and flows live).
  - All views filter on the gateway subnet, not on fixed IPs. The service log is near real time; flow and firewall
    logs arrive with a delay of 1–10 minutes.
- **Gateway on/off:** `enable_png` in `infra/40-databricks-network` shows the "before" state.
- **Gateway traffic mode:** `png_traffic_mode = "ALL_TRAFFIC"` in `infra/40-databricks-network` together with
  `png_allow_internet = true` in `infra/20-aws-network` routes serverless internet egress through the gateway, the
  customer firewall and NAT. Back to `SPECIFIC_DESTINATIONS` for the default setup.

## Teardown

Destroy in reverse order of deployment:

1. Bundle: `cd bundle && databricks bundle destroy` (app, MCP services, jobs).
2. UC objects created by scripts: connections in `ops_demo.tools` (`databricks connections delete ops_demo.tools.<service>_conn`),
   the foreign catalog `ops_inventory` and the connection `pngdemo_pg`.
3. Genie space: delete it in the workspace (it lives in your user folder).
4. Terraform stacks, in this order: `60`, `50`, `45`, `40`, `35`, `30`, `25`, `20`, `10`.
   - Delete the workspace (`10`) only after `40`, which owns the NCC and its workspace binding.
   - The gateway's network interfaces are removed asynchronously by Databricks. `infra/40-databricks-network` waits
     for that before it deletes the cross-account role.
5. Entra: delete the two app registrations created by `scripts/01-entra-apps.sh`.
6. DNS: release the DuckDNS name (or your own record) and delete the local token file.

## Cost

About USD 10 per day with the firewall off (NAT gateway, Transit Gateway attachments, ALB, Fargate, RDS, VPC
endpoints), plus about USD 10 per day while the firewall is on. Destroy the stacks when you don't need them.

## Disclaimer

This repository is provided as a starting point for learning and demonstration purposes only. It is not intended for
production use and may require additional hardening, testing and review before being used in any production
environment. The code is provided "as is", without warranty or support of any kind, express or implied, and you use
it at your own risk.

Parts of this repository were generated with the assistance of AI tools.
