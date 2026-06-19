# platypod — context for Claude

Personal homelab, two subsystems set up in order:

1. **[`infra/`](infra/README.md)** — the Kubernetes cluster (Talos VMs on Apple
   Silicon via vfkit + Terraform). dev = laptop; prod = mini4 + mini1.
2. **[`stack/`](stack/README.md)** — the workloads on top (Helm via Helmfile).

**Start with [README.md](README.md)** for the repo structure, end-to-end
lifecycle, and the dev-vs-prod table.

Each subsystem keeps its own thin `CLAUDE.md` pointing at its `README.md` + `docs/`:

- [infra/CLAUDE.md](infra/CLAUDE.md) → cluster provisioning, networking, recovery
- [stack/CLAUDE.md](stack/CLAUDE.md) → chart structure, conventions, services, auth

Custom container images live in `cyber-chef/`, `mediarvester/`, `pokeclicker/`,
`transmission-exporter/` (built to GHCR, consumed by the stack).

## Where to look (read the one file, not the whole tree)

Resolve the user's intent to a single doc, read it, follow its links from there.
The two subsystem `CLAUDE.md` files carry the critical rules — read the matching
one before editing under `infra/` or `stack/`.

| If the talk is about… | Start here |
|---|---|
| Cluster won't come up / died after host reboot | [infra/docs/troubleshooting.md](infra/docs/troubleshooting.md) + [infra/CLAUDE.md](infra/CLAUDE.md) rules |
| Public stack down after a router reboot (prod) | [infra/docs/troubleshooting.md](infra/docs/troubleshooting.md) (`make rearm-ingress`) |
| VM networking, NAT, ingress, MetalLB, storage wiring | [infra/docs/architecture.md](infra/docs/architecture.md) |
| Terraform/Talos gotchas, per-env state, certs, bastion | [infra/docs/decisions.md](infra/docs/decisions.md) |
| `make` targets / variables (cluster) | [infra/docs/make-targets.md](infra/docs/make-targets.md) |
| Adding/editing a service or its Helm chart | [stack/docs/conventions.md](stack/docs/conventions.md) + [stack/CLAUDE.md](stack/CLAUDE.md) rules |
| What a service is / which module it's in | [stack/docs/services.md](stack/docs/services.md), then `stack/src/<module>/README.md` |
| Auth (Authelia forward-auth, OIDC, LLDAP) | [stack/docs/authentication.md](stack/docs/authentication.md) |
| Deploy/lifecycle, dev-vs-prod, PV access | [stack/docs/operations.md](stack/docs/operations.md) |
| `make` targets / variables (stack) | [stack/docs/make-targets.md](stack/docs/make-targets.md) |
| A custom image (cyber-chef, mediarvester, …) | that dir's `README.md` |
