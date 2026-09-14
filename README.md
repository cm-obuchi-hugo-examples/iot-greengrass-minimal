# iot-greengrass-minimal

A minimal, self-contained lab for AWS IoT Greengrass V2: one Greengrass core
acting as a local MQTT gateway, and a fleet of client containers that
provision their own AWS IoT identity the first time they boot. Everything
here runs as Podman containers on a single machine; no physical device is
involved.

## Concept

One container (`core`) runs the full Greengrass V2 Nucleus with four
AWS-managed components deployed to it: client device auth, the Moquette MQTT
broker, the MQTT Bridge, and the IP detector — all inside a single JVM. This
is the only thing in the lab that ever opens an application MQTT session to
AWS IoT Core in the cloud. Any number of `client` containers connect only to
this local broker over mutual TLS; none of them is allowed to reach AWS IoT
Core's MQTT endpoint directly. A client's own AWS IoT identity does not
exist before it boots: on first start, it generates its own key pair and
CSR, connects briefly to AWS IoT Core with a shared, deliberately
low-privilege "claim" certificate, and uses AWS IoT fleet provisioning by
claim to get a certificate of its own and register a Thing — with the Thing
name, thing-group membership, and IoT policy all decided server-side by a
provisioning template, never by the device. No Terraform file, IoT policy,
or script in this repo ever names an individual client device: cores are
matched by a `lab-gg-core-*` naming convention, clients by
`lab-gg-device-*`, and the Greengrass deployment targets a thing group, not
a device. The practical result is that the client fleet's size is controlled
by exactly one input — the `--scale client=N` count you give
`podman compose` — with zero Terraform or IoT Core configuration change
required to grow or shrink it.

## Architecture

```
                          AWS IoT Core / Greengrass V2 (cloud)
                                      |
                  (1) claim MQTT, first boot only, 2 topics only
                  (2) HTTPS greengrass:Discover, every boot
                  (3) core's own MQTT session (Nucleus, jobs, shadow-for-
                      connectivity-info, deployments) -- persistent
                                      |
        +-----------------------------+-----------------------------+
        |                                                           |
   [ core container ]                                       (nothing else
   Nucleus + client device                                   ever connects
   auth + Moquette broker +                                   to the cloud
   MQTT Bridge + IP detector                                  MQTT endpoint)
   one JVM, one cert (lab-gg-core-01)
        |
        | local mTLS (10.89.40.0/24, no host-exposed port)
        |
   +----+----+----+---- ... ---+
   |    |    |    |            |
 client client client  ...   client        <- N containers, each with its
 (own cert + Thing,           own private key + cert, never shared
  lab-gg-device-<serial>)
```

Two distinct client-side credentials exist, and only one of them ever
touches the cloud on an ongoing basis:

- **The shared claim certificate** — used once, at first boot, to open an
  MQTT session directly to AWS IoT Core. Its IoT policy (`lab-gg-claim`)
  authorizes exactly two things: `CreateCertificateFromCsr` and
  `RegisterThing` against one named provisioning template. It can publish or
  subscribe on no application topic at all.
- **The device's own certificate**, issued during that provisioning — its
  IoT policy (`lab-gg-client-discovery`) grants `greengrass:Discover` and
  nothing else. It has no `iot:Connect`, `iot:Publish`, `iot:Subscribe`, or
  `iot:Receive` permission on AWS IoT Core at all, ever. Discovery itself is
  an HTTPS call, not an MQTT connection.

Every message a client sends or receives afterward (telemetry out, commands
in) goes over the local Moquette broker, through the MQTT Bridge, which is
the only thing that ever relays it to or from AWS IoT Core.

## Repository structure

| Path | Contents |
|---|---|
| `infra/10-account/` | Account-wide, rarely-changing resources: the IAM role AWS IoT assumes to run fleet provisioning (`lab-gg-provisioning-role`), and the Greengrass service-role-to-account association — created only if the account+Region doesn't already have one, since that association is a shared, account-level singleton. |
| `infra/20-fleet/` | Everything that changes per lab iteration: the core's Thing/certificate, the shared claim certificate and its policy, the client discovery policy, the fleet provisioning template, the token-exchange role/role alias, the thing groups, the Greengrass V2 deployment (Nucleus + the four client-device components), and Terraform `check` blocks that verify two of the lab's claims against the live registry. |
| `local/compose.yaml` | The Podman Compose runtime definition: one `core` service, one `client` service meant to be scaled, one bridge network, two named volumes. |
| `greengrass.env` | Static Nucleus environment variables for the core container (no secrets, no per-account values — checked into git). |
| `client-image/` | The self-provisioning client: `Containerfile`, `provision.py` (the fleet-provisioning-by-claim logic), `entrypoint.sh` (idempotent provision-once-then-discover-forever logic). |
| `scripts/` | `gen-core-csr.sh` / `gen-claim-csr.sh` (generate keys+CSRs locally), `gen-core-config.sh` (renders the core's `config.yaml` from live Terraform outputs), `associate.sh` (associates every current client Thing with the core device — the one operation with no thing-group form), `verify.sh` (checks the lab's claims against the running containers and the live registry), `cleanup-clients.sh` (deletes self-provisioned client Things Terraform never tracked), and three `check-*.sh` read-only scripts consumed by Terraform's `external`/`check` data sources. |

## Prerequisites

- Terraform >= 1.10 (built and tested with 1.15).
- An AWS account/credentials able to create IoT, Greengrass, and IAM
  resources, plus `iam:PassRole` for the roles this repo creates (the
  provisioning role is passed to AWS IoT's fleet provisioning template, and
  the token-exchange role is passed when creating its role alias).
- Podman with Compose support (`podman compose` or `podman-compose`).
- `openssl`, `jq`, `git`, `curl`.
- The Docker/Compose network `10.89.40.0/24` must not overlap any other
  local network or VPN route already active on your machine.
- Pinned Greengrass component versions (Nucleus, client device auth,
  Moquette, MQTT Bridge, IP detector) are in
  `infra/20-fleet/deployment.tf` — check there if you need to bump any of
  them.

## Runbook

All commands assume the repo root as the working directory unless noted.

### 1. Account-wide resources (once per AWS account+Region)

```bash
terraform -chdir=infra/10-account init
terraform -chdir=infra/10-account apply
```

### 2. Generate local key material

Neither script's private key ever enters Terraform state — Terraform only
signs the CSR each script produces.

```bash
scripts/gen-core-csr.sh
scripts/gen-claim-csr.sh
```

This writes `certs/lab-gg-core-01/{private.pem.key,device.csr,AmazonRootCA1.pem}`
and `certs/claim/{private.pem.key,claim.csr,AmazonRootCA1.pem}`. `certs/` is
gitignored.

### 3. Fleet-layer resources

```bash
cp infra/20-fleet/terraform.tfvars.example infra/20-fleet/terraform.tfvars
# edit it only if your certs/ layout differs from the defaults above
terraform -chdir=infra/20-fleet init
terraform -chdir=infra/20-fleet apply
```

This creates the core's Thing/certificate, the claim certificate, the
client discovery and claim IoT policies, the provisioning template, the
token-exchange role alias, the two thing groups, and deploys the four
client-device components (plus the Nucleus) to the core's thing group.

### 4. Render the core's local config

```bash
scripts/gen-core-config.sh
```

Reads `infra/20-fleet`'s Terraform outputs (endpoints, thing name, role
alias) and writes `config/config.yaml` (mounted read-only into the core
container) and `client.env` (the client containers' `IOT_DATA_ENDPOINT`).
Both are gitignored; re-run this any time those outputs change.

### 5. Clone the two upstream sources the images build from

```bash
git clone https://github.com/aws-greengrass/aws-greengrass-docker.git
git -C aws-greengrass-docker checkout c84c544ddbf854cbdd1798b1a4ace6af510a1bec

git clone --depth 1 --branch v1.31.0 \
  https://github.com/aws/aws-iot-device-sdk-python-v2.git \
  client-image/aws-iot-device-sdk-python-v2
```

`aws-greengrass-docker` is cloned at the repo root (`local/compose.yaml`
builds the `core` image from `../aws-greengrass-docker` with
`GREENGRASS_RELEASE_VERSION` matching the Nucleus version pinned in
`infra/20-fleet/deployment.tf`). `aws-iot-device-sdk-python-v2` is cloned
under `client-image/` at the tag matching the `awsiotsdk` version pinned in
`client-image/Containerfile`. Both paths are gitignored.

### 6. Start the fleet

If you're on macOS/Windows and the Podman machine isn't already running:

```bash
podman machine start
```

Then bring the whole lab up (`N` is the number of client containers):

```bash
podman compose -f local/compose.yaml up -d --build --scale client=N
```

### 7. Associate the fleet and verify

```bash
scripts/associate.sh
scripts/verify.sh
```

`associate.sh` associates every current member of the `lab-gg-clients`
thing group with the core device — `BatchAssociateClientDeviceWithCoreDevice`
takes explicit Thing names and has no thing-group form, so this has to run
after clients exist. `verify.sh` checks self-registration, identity
persistence, local-only client MQTT, targeted message delivery, and the
checkable half of core disposability against whatever is actually running
and registered.

### Scaling the fleet

Re-run step 6 with a larger count, then re-run association and
verification:

```bash
podman compose -f local/compose.yaml up -d --build --scale client=<bigger N>
scripts/associate.sh
scripts/verify.sh
```

Existing replicas keep their stored identity (their certificate lives on
the shared `lab-gg-clients-data` volume, keyed by the container's
hostname/serial) — only the new replicas provision. Do not run
`--force-recreate` on replicas that have already provisioned: a recreated
container gets a new random hostname, looks like a brand-new device, and
provisions a second Thing while orphaning the old one in the registry.
`podman restart` or `podman start` on an existing replica is safe and
reuses its identity.

### Teardown

```bash
podman compose -f local/compose.yaml down -v   # stops/removes containers and volumes
scripts/cleanup-clients.sh                     # deletes self-provisioned client Things Terraform never tracked
terraform -chdir=infra/20-fleet destroy
```

`terraform destroy` in `infra/20-fleet` is safe on its own terms — it never
created the account-wide provisioning role or Greengrass service role.
**Do not run `terraform destroy` in `infra/10-account`** unless you are
certain no other Greengrass core in this account/Region depends on the
service role it may have created — that association is one per
account+Region, shared with anything else running Greengrass there.

## What this deliberately does not include

- No CloudWatch integration: the token-exchange IAM policy grants only
  `s3:GetBucketLocation` (for resolving component artifacts) and
  deliberately omits the `logs:*` actions AWS's own default token-exchange
  policy includes, because the Log Manager component is never deployed.
- No IoT Rules Engine — nothing routes or transforms messages in the cloud;
  the only cloud-side routing is the MQTT Bridge's fixed topic mapping.
- No custom Greengrass components or IPC — the deployment only installs
  AWS-managed components (Nucleus, client device auth, Moquette, MQTT
  Bridge, IP detector).
- No application-level device shadow usage. The core's IoT policy grants
  some shadow-topic access, but that's Greengrass's own internal
  connectivity-info shadow, not a shadow feature exposed to client devices.
- No certificate rotation — `gen-core-csr.sh` and `gen-claim-csr.sh` refuse
  to overwrite an existing key unless you pass `--force`, and nothing
  automates re-issuing a certificate on a schedule.
- No second core or failover — the core Thing name (`lab-gg-core-01`) and
  the `core` Compose service are both singular; the wildcard naming
  convention (`lab-gg-core-*`) is there so a second core could be added by
  hand later, not because one exists today.
- No host-exposed port — `local/compose.yaml` never publishes Moquette's
  8883; it's reachable only from the `lab-gg-net` bridge network.

## Security notes

- Every private key in this lab (core, claim, and each client's own device
  key) is generated locally by OpenSSL — `gen-core-csr.sh`,
  `gen-claim-csr.sh`, and each client's `entrypoint.sh` — and never leaves
  the machine or container that generated it. Terraform only ever receives
  and signs a CSR (`aws_iot_certificate` with a `csr` argument); no private
  key passes through Terraform state.
- `certs/` (core and claim keys) is gitignored, as are the generated
  `config/config.yaml` and `client.env`.
- No static AWS credential is ever placed inside a container. The core
  exchanges its X.509 certificate for temporary AWS credentials at runtime
  via the IoT Greengrass token-exchange role alias
  (`infra/20-fleet/token-exchange.tf`); client containers never hold AWS
  credentials at all, only IoT certificates.
