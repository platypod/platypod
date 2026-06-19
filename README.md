# platypod

Personal home-server / homelab. Two subsystems, set up in order:

1. **[`infra/`](infra/README.md)** — the Kubernetes cluster itself (Talos Linux
   VMs on Apple Silicon macOS, via vfkit + Terraform/OpenTofu).
2. **[`stack/`](stack/README.md)** — the workload stack deployed onto that cluster
   (Helm charts via Helmfile).

## Repo structure

| Path | Role |
|------|------|
| [`infra/`](infra/README.md) | Cluster provisioning (Talos VMs, MetalLB, networking, ingress) |
| [`stack/`](stack/README.md) | Service stack (media, dev-tools, observability, …) deployed on the cluster |
| `cyber-chef/`, `mediarvester/`, `pokeclicker/`, `transmission-exporter/` | Custom container images built and pushed to GHCR, consumed by the stack |

## End-to-end lifecycle

### First-time dev

```sh
# 1. Provision the cluster
cd infra
make setup-host          # one-time: install socket_vmnet on this machine
make apply ENV=dev

# 2. Deploy services
cd ../stack
make install-deps
make setup-dev           # mkcert CA + TLS secret + Traefik CRDs + core deploy + DNS
make deploy              # full stack
```

### First-time prod

```sh
cd infra
make setup-host HOST=mini4 GATEWAY=10.0.2.1   # one-time per machine
make setup-host HOST=mini1 GATEWAY=10.0.1.1
make apply ENV=prod

cd ../stack
make install-deps
make install-crds ENV=prd
make install-csi  ENV=prd
make deploy ENV=prd
```

### Day-to-day

```sh
cd infra  && make restart ENV=dev          # cluster died after a host reboot
cd infra  && make rearm-ingress            # public stack down after a router reboot (prod)
cd stack  && make deploy MODULE=core       # redeploy one module
cd stack  && make destroy && cd ../infra && make destroy ENV=dev   # tear down
```

## Dev vs prod at a glance

| Concern | dev | prod |
|---------|-----|------|
| Hosts | local laptop (1 cp + 1 worker) | mini4 (cp1+w1) + mini1 (w2) |
| VM subnet | `192.168.122.0/24` | `10.0.2.0/24` (mini4), `10.0.1.0/24` (mini1) |
| MetalLB pool | `192.168.122.200-220` | `10.0.2.200-220` |
| Namespace | `dev-platypod` | `prd-platypod` |
| Domain | `platypod.local` | `platypod.ovh` |
| TLS | self-signed wildcard (mkcert) | ACME / Let's Encrypt |
| DNS | AdGuard + system resolver | public DNS |
| Storage | local hostPath on worker | Synology NFS (`192.168.1.30`) |

## Documentation

Each subsystem has its own `README.md` + `docs/` folder:

- **infra:** [README](infra/README.md) · [make targets](infra/docs/make-targets.md) · [architecture](infra/docs/architecture.md) · [decisions](infra/docs/decisions.md) · [troubleshooting](infra/docs/troubleshooting.md)
- **stack:** [README](stack/README.md) · [docs index](stack/docs/README.md) · [operations](stack/docs/operations.md) · [make targets](stack/docs/make-targets.md) · [conventions](stack/docs/conventions.md)
