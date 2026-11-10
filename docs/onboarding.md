# Onboarding a new internal service

How to make a new internal system (MCP server, REST API, database) available to Databricks serverless through the
private network gateway. This is the conceptual process; in this repository, the network-side steps are driven by
`services.yaml`.

## The idea: connectivity scales by network, not by service

The connectivity is set up **once** for the whole internal domain. A new service under that domain is covered
automatically by:

| Set up once | Covers every `<name>.<domain>` because |
|---|---|
| Gateway destination | it's a DNS **suffix** (`<domain>`), matched by suffix |
| Private DNS | the private zone has a **wildcard** record `*.<domain>` |
| TLS certificate | it's a **wildcard** certificate for `*.<domain>` |
| Firewall (`network` mode) | one **zone rule**: the gateway subnet may reach the services network |

What remains per service is: **run it, route it, govern it.**

## The layers

| # | Layer | Change per new service |
|---|---|---|
| 1 | Service (code, container, host) | **Yes**: run it in your network |
| 2 | Load balancer (front door for HTTP services) | **Yes**: one rule `Host = <name>.<domain>` → the service |
| 3 | DNS | No: wildcard record |
| 4 | TLS certificate | No: wildcard certificate |
| 5 | Gateway destination | No: domain suffix |
| 6 | Firewall | `network` mode: no. `per_service` mode: **yes**, one rule allowing the hostname for the Databricks zone |
| 7 | Unity Catalog | **Yes**: connection (+ MCP service or foreign catalog) and grants for account groups |
| 8 | Identity (services with SSO) | **Yes**: the service validates the user's Entra token; roles decide what each person may do |

## Step by step

1. **Decide**
   - name: `<name>.<domain>`;
   - type: MCP server, REST API or database;
   - identity: SSO with Entra (recommended) or none;
   - exposure: may the Databricks zone reach it at all (`databricks_zone` in `services.yaml`)?
2. **Run the service** in your network, for example as a container behind the internal load balancer.
3. **Route it:** add the load balancer rule from the hostname to the service. DNS, certificate and gateway already fit.
4. **Approve it in the firewall** (only in `per_service` mode): allow the hostname for the Databricks zone.
   In this repository, steps 2–4 are one entry in `services.yaml` plus `terraform apply` (`infra/20-aws-network`,
   `infra/30-aws-services`).
5. **Identity** (services with SSO): the service accepts tokens for the API app (audience) with the delegated scope,
   and checks app roles for sensitive actions (example: only `ServiceDesk.Agent` may change a request).
6. **Govern it in Unity Catalog**, depending on the type:

   | Type | Unity Catalog objects | Grants |
   |---|---|---|
   | MCP server | HTTP connection with per-user OAuth + **MCP service** in Unity Gateway | `EXECUTE` on the MCP service for account groups |
   | REST API | HTTP connection (bearer or OAuth); call it with `http_request` from SQL/notebooks, or put an MCP service in front of it for per-user access in apps and agents | `USE CONNECTION` for the groups that may call it |
   | Database | connection of the database type + **foreign catalog** (Lakehouse Federation), with a read-only database role | `USE_CATALOG`, `USE_SCHEMA`, `SELECT` |

   In this repository: `scripts/04-create-connections.sh` (HTTP connections), `bundle/databricks.yml`
   (`mcp_services`, grants), `scripts/07-postgres-federation.sh` (database example).
7. **Users sign in once** per service with per-user OAuth (Unity Gateway → MCPs).
8. **Use it:** add the MCP service to the app or agent (`app_mcp_services` in the bundle); SQL and notebooks use the
   connection or the foreign catalog.

## Variants

| Case | What's different |
|---|---|
| HTTP service as a container (MCP or REST) | The standard case above |
| Database (Postgres, …) | No load balancer: a DNS name under the domain pointing to the database, a firewall rule for its port (here 5432), Unity Catalog via Lakehouse Federation |
| Service that already runs elsewhere (another VPC, on-premises) | Either register its address as an **IP target** behind the load balancer (if it's routable from there), or give it its own name under the domain that points to it and serve that name with a publicly trusted certificate. The gateway destination and DNS suffix stay unchanged |
| Service without SSO | Same steps, but keep it out of the Databricks zone (`databricks_zone: false`, `per_service` firewall mode) until it authenticates its callers |

## Who does what

| Role | Steps |
|---|---|
| Service team | 1, 2, 5: the service and its identity integration |
| Network / platform team | 3, 4: one reviewed change to the registry (`services.yaml`), applied by Terraform |
| Data platform team | 6, 8: Unity Catalog objects and grants for account groups |
| Users | 7: sign in once |

**In one sentence:** the gateway, DNS and certificate are set up once for the domain, so onboarding a service is
running it, adding one load balancer rule (plus an optional firewall approval), and governing it in Unity Catalog.
