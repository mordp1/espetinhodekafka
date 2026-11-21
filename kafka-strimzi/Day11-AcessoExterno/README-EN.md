# External Access to Kafka on Kubernetes — Listeners, Gateway API, DNS and Certificates (Strimzi)

> **Goal:** answer the question that blocks most teams moving Kafka to Kubernetes: **"how does a
> client that is *outside* the cluster talk to Kafka — with DNS, TLS and authentication that I
> control?"** The Day has two parts. **Part 1:** how external access really works (why "the
> bootstrap connects and then everything times out"), the Strimzi listener types, which one to pick
> and why we do **not** recommend Istio. **Part 2:** a **complete lab that simulates production**: our
> own PKI (a self-signed root CA with cert-manager), **DNS** for the local machine and for the cluster,
> **Gateway API with TLS passthrough** (Envoy Gateway) and Strimzi's `tlsroute` listener, **per-team
> mTLS** with ACLs, and **distribution of the CA and of the credentials to the teams** (trust-manager).
> Every scenario was run end to end on kind (Strimzi 1.3.1, Kafka 4.3.2, Kubernetes 1.34, cert-manager
> 1.21.3, trust-manager 0.26.0, Envoy Gateway 1.10.0) — the outputs shown are real. What was **not**
> run is listed, plainly, in section 12.
>
> **This README is also the execution script:** the `bash` blocks of Part 2 run in order, copy and
> paste, and were validated from scratch on a clean kind cluster.

---

## Index

**Part 1 — How external access works**
1. [The problem: two "addresses" and a connection that seems to work](#1-the-problem-two-addresses-and-a-connection-that-seems-to-work)
2. [Strimzi 1.3.1 listener types](#2-strimzi-131-listener-types)
3. [Which one to choose (and Istio, the OpenShift Router...)](#3-which-one-to-choose-and-istio-the-openshift-router)
4. [Certificates: three chains of trust](#4-certificates-three-chains-of-trust)

**Part 2 — The lab**
5. [Architecture and prerequisites](#5-architecture-and-prerequisites)
6. [Lab layout](#6-lab-layout)
7. [Step by step](#7-step-by-step)
8. [Failure scenarios (all executed)](#8-failure-scenarios-all-executed)
9. [Going to production](#9-going-to-production)
10. [Gotchas the lab hit](#10-gotchas-the-lab-hit)
11. [Suggested video script](#11-suggested-video-script)
12. [What this lab does NOT cover (honestly)](#12-what-this-lab-does-not-cover-honestly)
13. [Cleanup](#13-cleanup)
14. [References](#14-references)

---

# Part 1 — How external access works

## 1. The problem: two "addresses" and a connection that seems to work

A Kafka client does **not** talk to "the cluster": it talks to **specific brokers**. The connection happens
in two stages:

```text
   client                           bootstrap                         brokers
      │  1. connects to bootstrap:9094       │
      ├─────────────────────────────────────►│
      │  2. "give me the metadata"           │
      │◄─────────────────────────────────────┤  reply: broker 0 = ADDR0, broker 1 = ADDR1, broker 2 = ADDR2
      │  3. connects to the LEADER of each partition, using the addresses from the reply (advertised.listeners)
      ├────────────────────────────────────────────────────────────────────────►│  ADDR0 / ADDR1 / ADDR2
```

The bootstrap address is **only used for stage 1**. From stage 3 on, the client uses what the **broker
advertised** (`advertised.listeners`). That is why the most classic external access error is:

> *"The bootstrap connects, `kafka-topics --list` works, but producing/consuming times out."*

Almost always the broker is advertising an address that **only exists inside the cluster** (or a node IP the
client cannot reach). So external access needs **one address per broker + one for bootstrap**, all
**resolvable (DNS)**, **reachable (network)** and — with TLS — **present in the certificate (SAN)**. These
are three independent problems; the lab handles each one (and breaks each one on purpose in section 8).

## 2. Strimzi 1.3.1 listener types

Values accepted in `spec.kafka.listeners[].type` (read from this version's operator CRD):

| Type | What Strimzi creates | Address the client uses | Notes |
|---|---|---|---|
| `internal` | only the headless/bootstrap Service | `my-cluster-kafka-bootstrap.kafka.svc:9092` | inside the cluster only (Days 1–10) |
| `cluster-ip` | **one `ClusterIP` per broker** | whatever **you** put in front (Gateway/proxy) | a building block: for those who expose with their own solution |
| `nodeport` | one `NodePort` per broker + bootstrap | **node** IP/DNS + high port | simple, but needs reachable nodes and high ports; this is where the section 8 (A) error is born |
| `loadbalancer` | **one `LoadBalancer` per broker + one for bootstrap** | each LB's IP/DNS | the cloud default; **N+1 load balancers** (cost and quota), each on its own port |
| `ingress` | one `Ingress` per broker (NGINX, TLS passthrough) | `bootstrap.example.com:443` | **deprecated** in 1.3.1 (the CRD says so); depends on NGINX Ingress |
| `tlsroute` | **one `TLSRoute` (Gateway API v1) + `ClusterIP` per broker** | `bootstrap.example.com:443` | **the modern way** — used in this lab |
| `route` | OpenShift `Route` (passthrough) | the OpenShift **Router** hostname, port 443 | OpenShift only; same idea as `tlsroute` |

**The trick of `ingress`/`tlsroute`/`route`:** all three use **a single port (443) and a single IP**. The proxy
reads the **SNI** (the server name, sent in clear at the start of the TLS handshake) and forwards the
*encrypted* stream to the right broker. That is why each broker needs **its own DNS name** (`broker-0.…`,
`broker-1.…`) and the listener **must have `tls: true`**: without TLS there is no SNI.

In Strimzi 1.3.1 the CRD describes `ingress` as *deprecated*, and the NGINX Ingress Controller project was
announced as retired — `tlsroute` (Gateway API) is the natural successor. It is what the lab uses.

```text
                     laptop / external team                         cluster
  bootstrap.kafka.lab.test ─┐
  broker-0.kafka.lab.test  ─┤  DNS → same IP      ┌──────────────┐  TLS passthrough (SNI)   ┌──────────────┐
  broker-1.kafka.lab.test  ─┼─────────:443───────►│ Gateway      ├─────────────────────────►│ broker 0/1/2 │
  broker-2.kafka.lab.test  ─┘                     │ (Envoy)      │  1 TLSRoute per name     │ (terminates TLS)│
                                                  └──────────────┘                          └──────────────┘
```

## 3. Which one to choose (and Istio, the OpenShift Router...)

| Situation | Choice | Why |
|---|---|---|
| Only apps in the same cluster | `internal` | nothing to expose |
| External clients, cluster with **Gateway API** (or you can install it) | **`tlsroute`** | one IP/port, names per broker, end-to-end TLS, mTLS works |
| Cloud, no Gateway API, few brokers | `loadbalancer` | simple; watch the cost of N+1 LBs |
| **OpenShift** | `route` | the **OpenShift Router** plays the Gateway's role: Strimzi creates the passthrough `Route`s and the hostname comes from the Router (port 443). Same logic as `tlsroute`; **not exercised in this lab** (section 12) |
| Development / kind without a proxy | `nodeport` | works, but see the section 8 (A) trap |
| You already run your own proxy/mesh | `cluster-ip` | Strimzi only hands you the Services; the routing is yours |

### And Istio?

**We do not recommend putting Kafka (or the external access to it) in an Istio mesh.** Two discussions in
the Strimzi project show what happens, and both are worth reading:

- [#11869](https://github.com/orgs/strimzi/discussions/11869): after upgrading the operator to 0.47.0, the
  `CruiseControlMetricsReporter` could not connect to the brokers with Istio sidecars. The maintainers'
  answer: **Strimzi does not support Istio and there is no plan to**; the mesh also does not understand the
  Kafka protocol (so "TLS inside TLS" and no routing gain).
- [#12200](https://github.com/orgs/strimzi/discussions/12200) (opened by us): with Istio + Cilium, the Cruise Control
  *metrics reporter* uses the headless Service `<cluster>-kafka-brokers:9091`, which in KRaft includes the
  **controllers**; the sidecar redirected connections to pods that do not listen on that port (and captured
  DNS), and TLS/SASL authentication failed in a loop. The maintainer replied: *"Strimzi does not support
  Istio… the general advice would be to avoid it"*.

What worked for people who insist on the mesh (reported in the discussions; **not reproduced in this lab**):
turning injection off on the Kafka pods (`sidecar.istio.io/inject: "false"` in the `KafkaNodePool`
`template.pod.metadata.annotations`), or excluding the inter-broker ports
(`traffic.sidecar.istio.io/excludeInboundPorts` / `excludeOutboundPorts`) and turning DNS capture off
(`ISTIO_META_DNS_CAPTURE: "false"`). Note that **all** the solutions are "take Kafka out of the mesh": Kafka
already has TLS, authentication and ACLs in the protocol itself.

## 4. Certificates: three chains of trust

External access with TLS brings together **three** different things that people tend to mix up:

| # | What | Issued by | Trusted by | In this lab |
|---|---|---|---|---|
| 1 | Strimzi **Cluster CA** | Strimzi itself (generated, renewed automatically) | the brokers among themselves and internal listeners | `my-cluster-cluster-ca-cert` — we do **not** give it to anyone |
| 2 | Strimzi **Clients CA** | Strimzi itself | the **brokers**, to validate each **client's** certificate (mTLS) | signs the certificate of each `KafkaUser` |
| 3 | **Listener certificate** (what the client sees in the handshake) | **your PKI** (here: cert-manager) | the **clients**, to validate the broker | `kafka-external-tls`, signed by the *Lab Root CA* |

Why not use the Cluster CA on the external listener? Because you would have to distribute **Strimzi's
internal CA** (which is renewed periodically) to every team, and because in companies the security team wants
certificates from the **corporate CA**. Strimzi lets you replace just one listener's certificate with
`brokerCertChainAndKey` (a `Secret` with `tls.crt` and `tls.key`).

Rules the lab confirmed (each has a scenario in section 8):

- **Every name the client uses must be in the certificate's SAN** (bootstrap *and* each broker). The Java
  client validates the hostname (scenario B).
- The private key must be **PKCS#8** (`BEGIN PRIVATE KEY`). cert-manager's default (PKCS#1) takes the broker
  down (scenario C).
- With **TLS passthrough** the Gateway does **not** see the certificate: the broker terminates TLS. That is why
  mTLS and your own certificate work. (With *terminate* at the Gateway, mTLS with the broker is gone.)
- What teams need to trust is **only the public root CA** — never a private key.

---

# Part 2 — The lab

## 5. Architecture and prerequisites

```text
 ┌─────────────────────────── your laptop ──────────────────────────┐
 │  kafka-client.sh / kafka-*.sh   (names *.kafka.lab.test via DNS) │
 │   local DNS: dnsmasq :5354 → 127.0.0.1   (or /etc/hosts)         │
 └───────────────────────────────┬──────────────────────────────────┘
                          :443  (kind extraPortMappings → NodePort 30443)
 ┌───────────────────────────────▼──────── kind: strimzi-day11 (1 control-plane + 3 workers) ─────────────┐
 │  Envoy Gateway ── Gateway "kafka-gateway" (TLS passthrough, *.kafka.lab.test)                          │
 │      │ TLSRoute bootstrap / broker-0 / broker-1 / broker-2   (created and kept by Strimzi)             │
 │      ▼                                                                                                 │
 │  my-cluster (3 dual-role nodes): internal listener :9093 (mTLS)  and  external :9094 (tlsroute, mTLS)  │
 │      ▲ listener certificate                             ▲ the Clients CA signs the KafkaUsers          │
 │  cert-manager: selfsigned → Lab Root CA → kafka-external (SAN: bootstrap + 3 brokers)                  │
 │  trust-manager: copies the Lab Root CA (public) into the teams' namespaces ─► ns team-orders           │
 │  CoreDNS: *.kafka.lab.test → the Gateway's Service (team apps resolve the SAME names)                  │
 └────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Component | Version | Role |
|---|---|---|
| Kubernetes (kind) | 1.34.0 (`kindest/node:v1.34.0`) | Strimzi 1.3.x requires **≥ 1.32** (an older `kind` defaults to 1.31) |
| Strimzi | 1.3.1 (chart `strimzi/strimzi-kafka-operator`) | operator; `tlsroute` listener |
| Kafka | 4.3.2 (KRaft, 3 dual-role nodes) | — |
| cert-manager | v1.21.3 | the lab PKI, as code |
| trust-manager | v0.26.0 | delivers the public CA to the teams' namespaces |
| Envoy Gateway | v1.10.0 (ships the Gateway API CRDs, `TLSRoute` v1) | `Gateway` implementation |

**Prerequisites:** `docker` (≥ 6 GB of memory for Docker; the lab used ~5 GB), `kind`, `kubectl`, `helm`,
`openssl`, `python3`. **Every `kubectl` command in the lab uses `--context kind-strimzi-day11` explicitly**
(through the `kx` shortcut below): if your machine has other contexts, nothing runs on the wrong cluster.

```bash
cd kafka-strimzi/Day11-AcessoExterno
kx() { kubectl --context kind-strimzi-day11 "$@"; }      # use it in EVERY new terminal
```

## 6. Lab layout

```text
Day11-AcessoExterno/
├── README.md / README-EN.md
├── kind-config.yaml              # 443 → NodePort 30443 (the lab's "load balancer") + NodePorts 31090-31093 (scenario A)
└── lab/
    ├── up.sh                     # kind + cert-manager + trust-manager + Envoy Gateway + Strimzi (idempotent)
    ├── manifests/
    │   ├── 00-gateway.yaml       # EnvoyProxy + GatewayClass + Gateway (TLS passthrough)
    │   ├── 10-pki.yaml           # selfsigned → Lab Root CA → ClusterIssuer lab-ca → Certificate kafka-external
    │   ├── 20-kafka.yaml         # KafkaNodePool + Kafka (internal and external=tlsroute listeners)
    │   ├── 30-topics-users.yaml  # 2 topics and 2 KafkaUsers (team-orders, team-payments) with ACLs
    │   ├── 40-trust-bundle.yaml  # trust-manager Bundle + namespace team-orders
    │   ├── 41-team-orders-client.yaml   # the pod a team runs in its own namespace
    │   └── scenario-a-*.yaml     # JSON patches for scenario A (nodeport)
    └── scripts/
        ├── dns-local.sh          # dnsmasq (laptop)        dns-cluster.sh   # CoreDNS (pods)
        ├── client-bundle.sh      # the "package" the platform team hands to a team
        ├── kafka-client.sh       # runs the Kafka tools in a container, as an external team would
        └── wait-kafka.sh         # waits for Kafka to be Ready AND to stop restarting
```

## 7. Step by step

### 7.1 The platform (cluster, cert-manager, trust-manager, Envoy Gateway, Strimzi)

```bash
lab/up.sh
```

```text
platform ready on context kind-strimzi-day11
```

```bash
kx get pods -A | grep -E "cert-manager|trust-manager|envoy|strimzi"
```

Six platform pods: `cert-manager` (+ `cainjector` and `webhook`), `trust-manager`, `envoy-gateway` and the
`strimzi-cluster-operator`. Strimzi watches only the `kafka` namespace.

### 7.2 DNS — the name the client uses must resolve to the Gateway

The names are `bootstrap.kafka.lab.test` and `broker-{0,1,2}.kafka.lab.test` (the `.test` TLD is reserved and
will never exist on the internet). There are **two** "DNS"es to solve:

**(a) The laptop's DNS.** A wildcard zone `*.lab.test → 127.0.0.1` in a dnsmasq container:

```bash
lab/scripts/dns-local.sh up
```

```text
dnsmasq up on 127.0.0.1:5354. Now (once, sudo):
  sudo mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\nport 5354\n' | sudo tee /etc/resolver/lab.test
```

Run the printed `sudo` (the script does **not** run it): on macOS, the file in `/etc/resolver/` sends only
`*.lab.test` queries to dnsmasq. Port **5354**: 5353 already belongs to mDNSResponder (Bonjour) and Docker
refuses the bind. The two-line alternative, with no container, is `/etc/hosts`:

```bash
echo '127.0.0.1 bootstrap.kafka.lab.test broker-0.kafka.lab.test broker-1.kafka.lab.test broker-2.kafka.lab.test' | sudo tee -a /etc/hosts
```

```bash
lab/scripts/dns-local.sh test
```

```text
dnsmasq direct:
127.0.0.1
127.0.0.1
127.0.0.1
what the OS resolver says (needs /etc/resolver/lab.test):
  (not resolving through the OS yet)       # ← this is what you see BEFORE the sudo; afterwards the ip_address shows up
```

**(b) DNS inside the cluster.** Apps of **other teams, in other namespaces**, must use *exactly* the same
names (and therefore the same certificate). One `rewrite` line in CoreDNS points `*.kafka.lab.test` to the
Gateway's Service:

```bash
lab/scripts/dns-cluster.sh
```

```text
CoreDNS apply: *.kafka.lab.test -> envoy-kafka-kafka-gateway-bf6d80f0.envoy-gateway-system
```

```bash
kx run dnscheck --rm -i --restart=Never --image=busybox:1.36 -- nslookup broker-1.kafka.lab.test 2>&1 | grep -E "Name|Address" | tail -2
```

```text
Name:	envoy-kafka-kafka-gateway-bf6d80f0.envoy-gateway-system.svc.cluster.local
Address: 10.96.219.170
```

> **In production** this is a real DNS zone (Route 53, Cloud DNS, ExternalDNS) with one record for the
> bootstrap and one per broker pointing to the Gateway's load balancer IP (section 9).

### 7.3 The PKI — the root CA and the listener certificate, as code

```bash
kx apply -f lab/manifests/10-pki.yaml
kx -n kafka get certificate
```

```text
NAME             READY   SECRET               AGE
kafka-external   True    kafka-external-tls   26s
```

The chain is `selfsigned → lab-root-ca (root, 10 years) → lab-ca (ClusterIssuer) → kafka-external`. The points
that matter in [`10-pki.yaml`](lab/manifests/10-pki.yaml): the `dnsNames` (the **SAN**: bootstrap and the 3
brokers), `privateKey.encoding: PKCS8` (scenario C) and `rotationPolicy: Always` (a new key on every renewal).

### 7.4 The Gateway — the "front door"

```bash
kx apply -f lab/manifests/00-gateway.yaml
kx -n kafka get gateway
```

```text
NAME            CLASS   ADDRESS      PROGRAMMED   AGE
kafka-gateway   envoy   172.18.0.6   True         26s
```

The `Gateway` has one listener with `protocol: TLS`, `mode: Passthrough`, `hostname: "*.kafka.lab.test"`:
Envoy **decrypts nothing**, it only reads the SNI. Strimzi creates the `TLSRoute`s, but does **not** create the
`Gateway` — that belongs to the platform team. Two details in the manifest are *lab* details (commented in the
file): Envoy's `Service` is a `NodePort` 30443 (kind publishes it on `localhost:443`) and
`externalTrafficPolicy: Cluster` (section 10, no. 1).

### 7.5 Kafka with the `tlsroute` listener

```bash
kx apply -f lab/manifests/20-kafka.yaml
kx -n kafka wait kafka/my-cluster --for=condition=Ready --timeout=600s
```

The part that matters (the rest is in [`20-kafka.yaml`](lab/manifests/20-kafka.yaml)):

```yaml
- name: external
  port: 9094
  type: tlsroute
  tls: true                      # required: the Gateway does passthrough, the broker terminates TLS
  authentication: { type: tls }  # mTLS: the client proves who it is with a certificate from the Clients CA
  configuration:
    parentRefs:                  # which Gateway the generated TLSRoutes attach to
      - { group: gateway.networking.k8s.io, kind: Gateway, name: kafka-gateway, namespace: kafka, sectionName: kafka }
    bootstrap: { host: bootstrap.kafka.lab.test }
    hostTemplate: broker-{nodeId}.kafka.lab.test
    brokerCertChainAndKey:       # OUR certificate (lab PKI), instead of the one from the Cluster CA
      secretName: kafka-external-tls
      certificate: tls.crt
      key: tls.key
```

The cluster was `Ready` about **80 s** after the `apply`. What Strimzi created:

```bash
kx -n kafka get tlsroute -o 'custom-columns=NAME:.metadata.name,HOSTNAMES:.spec.hostnames[0],BACKEND:.spec.rules[0].backendRefs[0].name,PORT:.spec.rules[0].backendRefs[0].port'
```

```text
NAME                         HOSTNAMES                  BACKEND                               PORT
my-cluster-dual-role-0       broker-0.kafka.lab.test    my-cluster-dual-role-0                9094
my-cluster-dual-role-1       broker-1.kafka.lab.test    my-cluster-dual-role-1                9094
my-cluster-dual-role-2       broker-2.kafka.lab.test    my-cluster-dual-role-2                9094
my-cluster-kafka-bootstrap   bootstrap.kafka.lab.test   my-cluster-kafka-external-bootstrap   9094
```

```bash
kx -n kafka get kafka my-cluster -o jsonpath='{range .status.listeners[*]}{.name}{"  "}{.bootstrapServers}{"\n"}{end}'
```

```text
external  bootstrap.kafka.lab.test:443
internal  my-cluster-kafka-bootstrap.kafka.svc:9093
```

Notice: Kafka listens on **9094**, the client uses **443** — Strimzi already advertises the Gateway's port.

### 7.6 Teams, topics and identities

```bash
kx apply -f lab/manifests/30-topics-users.yaml
kx -n kafka get kafkauser,kafkatopic
```

```text
NAME                                       CLUSTER      AUTHENTICATION   AUTHORIZATION   READY
kafkauser.kafka.strimzi.io/team-orders     my-cluster   tls              simple          True
kafkauser.kafka.strimzi.io/team-payments   my-cluster   tls              simple          True

NAME                                          CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
kafkatopic.kafka.strimzi.io/orders.events     my-cluster   3            3                    True
kafkatopic.kafka.strimzi.io/payments.events   my-cluster   3            3                    True
```

Each team has **one mTLS identity** (`CN=team-orders`) and ACLs only on its own prefix (`orders.`/`payments.`).

### 7.7 The "package" the platform team hands to a team

```bash
lab/scripts/client-bundle.sh team-orders lab/bundle-team-orders
lab/scripts/client-bundle.sh team-payments lab/bundle-team-payments
```

```text
bundle for team-orders -> lab/bundle-team-orders/  (ca.crt is public; keystore.pem is a SECRET)
```

| File | What it is | Sensitive? |
|---|---|---|
| `ca.crt` | the **Lab Root CA** (public): "trust whoever it signed" | **no** — the same for every team |
| `keystore.pem` | the team's private key + client certificate (from the Clients CA) | **yes** — only that team |
| `client.properties` | `security.protocol=SSL`, truststore and keystore in **PEM** (no `keytool`/PKCS12) | no |

(`lab/bundle-*` is in `.gitignore`: never commit a `keystore.pem`.)

With the package, the team uses the Kafka tools. In a container (`kafka-client.sh` already maps the 4 names to
the laptop, where kind publishes 443 — with the DNS from 7.2 you can run the tools natively):

```bash
BS=(--bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties)
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-topics.sh "${BS[@]}" --list
```

```text
orders.events
```

The orders team only **sees** its own topic (the `Describe` ACL is per prefix). Producing and consuming:

```bash
printf 'order-1\norder-2\norder-3\n' | lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-producer.sh "${BS[@]}" --topic orders.events
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-consumer.sh "${BS[@]}" --topic orders.events --group team-orders-app --from-beginning --max-messages 3 --timeout-ms 20000
```

```text
order-1
order-2
order-3
Processed a total of 3 messages
```

And the **border between teams** — `team-orders` trying to write to the payments topic:

```bash
echo x | lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-console-producer.sh "${BS[@]}" --topic payments.events
```

```text
ERROR [Producer clientId=console-producer] Topic authorization failed for topics [payments.events]
```

To see the handshake the way the client sees it (and prove the Gateway hands over **our** certificate, picked by
the SNI, without decrypting anything):

```bash
openssl s_client -connect 127.0.0.1:443 -servername broker-1.kafka.lab.test \
  -CAfile lab/bundle-team-orders/ca.crt -verify_hostname broker-1.kafka.lab.test </dev/null 2>/dev/null \
  | grep -E "^ *[0-9] s:|^ *i:|Verification|Verify return"
```

```text
 0 s:
   i:CN=Espetinho de Kafka Lab Root CA
Verification: OK
Verify return code: 0 (ok)
```

(`-connect 127.0.0.1:443` + `-servername` tests **without** depending on DNS: good for separating a "DNS
problem" from a "certificate problem".)

### 7.8 Distributing trust and credentials to the teams

Two things reach a team, with opposite sensitivities:

1. **The root CA (public)** — distributed by **trust-manager**: a `Bundle` copies `tls.crt` of `lab-root-ca` to a
   `ConfigMap` in *every namespace labelled `kafka.lab/trust-ca=true`* and keeps it up to date (if the CA is
   rotated, every team gets the new one). The CA's private key never leaves the `cert-manager` namespace.
2. **The team identity (private)** — the `KafkaUser` `Secret`. For someone **outside** the cluster it is the
   `keystore.pem` from the previous step, delivered through a secure channel (vault/secret manager). For
   someone **inside**, the `Secret` must exist in the team's namespace (here copied by hand; Day 5's
   **KafkaAccessOperator** automates this).

```bash
kx apply -f lab/manifests/40-trust-bundle.yaml
kx -n team-orders get cm kafka-lab-ca -o jsonpath='{.data.ca\.crt}' | openssl x509 -noout -subject
```

```text
subject=CN=Espetinho de Kafka Lab Root CA
```

```bash
kx -n kafka get secret team-orders -o json \
  | python3 -c 'import sys,json; s=json.load(sys.stdin); s["metadata"]={"name":"team-orders","namespace":"team-orders"}; print(json.dumps(s))' \
  | kx apply -f -
kx apply -f lab/manifests/41-team-orders-client.yaml
kx -n team-orders wait --for=condition=Ready pod/orders-app --timeout=120s
```

The team's pod mounts the CA (the trust-manager `ConfigMap`) and the identity (the `Secret`) and connects through
the **same external names** — resolved by the CoreDNS from 7.2:

```bash
kx -n team-orders exec orders-app -- /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server bootstrap.kafka.lab.test:443 --consumer.config /tmp/client.properties \
  --topic orders.events --group team-orders-pod --from-beginning --max-messages 3 --timeout-ms 30000
```

```text
Processed a total of 3 messages
```

And the same ACL border holds inside the cluster (`Topic authorization failed for topics [payments.events]`).

## 8. Failure scenarios (all executed)

Each scenario reproduces a real day-to-day error, shows **the exact message** and **how to diagnose it**.

### Scenario A — The bootstrap connects, the brokers do not (`nodeport` without `advertisedHost`)

Add a `nodeport` listener that says nothing about hostnames (JSON patch; lab only, plaintext and with
`ANONYMOUS` as super user, so that the failure is about the **network** and not about TLS/ACLs):

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-nodeport-broken.yaml
lab/scripts/wait-kafka.sh
kx -n kafka get kafka my-cluster -o jsonpath='{.status.listeners[?(@.name=="nodeport")].bootstrapServers}{"\n"}'
```

```text
172.18.0.3:31090,172.18.0.5:31090,172.18.0.6:31090        # ← kind NODE IPs (Docker's internal network)
```

(~100 s until `Ready`.) The bootstrap answers **from the laptop**, but look at what it returns:

```bash
lab/scripts/kafka-client.sh none kafka-broker-api-versions.sh --bootstrap-server host.docker.internal:31090
```

```text
172.18.0.3:31092 (id: 1 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
172.18.0.6:31093 (id: 2 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
172.18.0.5:31091 (id: 0 rack: null isFenced: false) -> ERROR: org.apache.kafka.common.errors.TimeoutException: Failed to send request after 5000 ms.
```

This is the section 1 error: the **metadata** (stage 2) worked and listed the brokers by `172.18.0.x` IPs, which
the client **cannot reach**. A `consumer` ends in `TimeoutException` and `Processed a total of 0 messages`.
**One-line diagnosis:** look at the address each broker *advertises* (`id: 0 … 172.18.0.5:31091`), not the
bootstrap one. **Fix:** tell the broker the address the *client* must use
([`scenario-a-nodeport-fixed.yaml`](lab/manifests/scenario-a-nodeport-fixed.yaml): `advertisedHost` + `advertisedPort`):

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-nodeport-fixed.yaml
lab/scripts/wait-kafka.sh
lab/scripts/kafka-client.sh none kafka-console-consumer.sh --bootstrap-server host.docker.internal:31090 \
  --topic orders.events --from-beginning --max-messages 3 --timeout-ms 20000
```

```text
order-1
order-2
order-3
Processed a total of 3 messages
```

(`host.docker.internal` is a name that resolves to the laptop both from inside a container and from the laptop
itself — on Docker Desktop. In production it would be a DNS name pointing to the nodes. **Prefer `tlsroute` or
`loadbalancer`**: `nodeport` pushes this problem onto you.) Go back to the base state:

```bash
kx -n kafka patch kafka my-cluster --type json --patch-file lab/manifests/scenario-a-cleanup.yaml
lab/scripts/wait-kafka.sh
```

### Scenario B — The name is not in the certificate (SAN)

Simulates "I scaled the cluster / changed the `hostTemplate` and forgot to update the certificate": remove
`broker-2` from the SAN.

```bash
kx -n kafka patch certificate kafka-external --type json -p '[{"op":"remove","path":"/spec/dnsNames/3"}]'
EXPECT_ROLL=1 lab/scripts/wait-kafka.sh
```

Two facts measured here: (1) **Strimzi only notices the new `Secret` on its next reconciliation** — about
**60 s** after cert-manager reissues; (2) it then does a **rolling restart** of the brokers (~70 s). Changing a
listener's certificate **always restarts the cluster**. The client:

```bash
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-broker-api-versions.sh --bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties
```

```text
ERROR [LegacyAdminClient clientId=admin-1] Connection to node 2 (broker-2.kafka.lab.test/192.168.65.254:443) failed authentication due to: SSL handshake failed
broker-0.kafka.lab.test:443 (id: 0 rack: null isFenced: false) -> (
```

The exact cause is in the exception chain (`kafka-topics.sh --describe --topic orders.events` prints it
clearly):

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_unknown) No subject alternative DNS name matching broker-2.kafka.lab.test found.
```

Note: **the bootstrap worked** (its name is in the SAN); the one that fails is **node 2**, which only shows up in
stage 3. Diagnosis without Kafka, and **without DNS** (`-servername` picks the broker by SNI):

```bash
openssl s_client -connect 127.0.0.1:443 -servername broker-2.kafka.lab.test \
  -verify_hostname broker-2.kafka.lab.test -CAfile lab/bundle-team-orders/ca.crt </dev/null 2>&1 | grep -E "Verif"
```

```text
verify error:num=62:hostname mismatch
Verification error: hostname mismatch
```

Fix: put the name back (`kx apply -f lab/manifests/10-pki.yaml`) and wait for the next rolling restart.
**Production lesson:** the SAN is part of the cluster's *contract*. Adding a broker = adding its name to the
certificate **first** (or using a wildcard `*.kafka.example.com` — less restrictive, but without this step).

### Scenario C — A PKCS#1 private key takes the broker down

cert-manager generates the key in **PKCS#1** (`BEGIN RSA PRIVATE KEY`) by default. Strimzi accepts the `Secret`
without complaining, the rolling restart starts… and the broker does not come up. To reproduce, change the
encoding and **force the reissue** (changing only `encoding` does not reissue; `cmctl renew` is the official way
— without it, a declarative trick is to push `renewBefore` right up to the `duration`):

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"privateKey":{"encoding":"PKCS1"},"renewBefore":"2159h59m"}}'
kx -n kafka get secret kafka-external-tls -o jsonpath='{.data.tls\.key}' | base64 -d | head -1
```

```text
-----BEGIN RSA PRIVATE KEY-----
```

About 2–3 minutes later (the time Strimzi takes to notice and restart the first broker):

```bash
kx -n kafka get pods | grep dual-role
```

```text
my-cluster-dual-role-0   1/1   Running            0             22m
my-cluster-dual-role-1   0/1   CrashLoopBackOff   4 (43s ago)   2m27s
my-cluster-dual-role-2   1/1   Running            0             22m
```

```bash
kx -n kafka logs my-cluster-dual-role-1 | grep -E "Fatal error|Private key|InvalidKeySpec"
```

```text
ERROR [main] BrokerServer:86 - [BrokerServer id=1] Fatal error during broker startup. Prepare to shutdown
org.apache.kafka.common.errors.InvalidConfigurationException: Invalid PEM keystore configs
Caused by: org.apache.kafka.common.errors.InvalidConfigurationException: Private key could not be loaded
Caused by: java.security.spec.InvalidKeySpecException: java.security.InvalidKeyException: Unable to decode key
```

Notice the danger: the **`Kafka` stays `Ready=True`** the whole time, and the other two brokers (still with the old
certificate) keep serving. The cluster is **one broker away from losing `min.insync.replicas`** and nothing
shouted. This is an alert to write (pod in `CrashLoopBackOff`, Day 10). Fix — `PKCS8`, which
[`10-pki.yaml`](lab/manifests/10-pki.yaml) already has:

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"privateKey":{"encoding":"PKCS8"},"renewBefore":"2159h59m"}}'
```

Broker 1 was back to `Running` about **2 minutes** later (the mounted `Secret` was updated and the next restart
attempt already read the PKCS#8 key). Re-apply `10-pki.yaml` to put `renewBefore` back to 720 h and use
`lab/scripts/wait-kafka.sh` to wait for stability.

### Scenario D — The three client errors you will see in tickets

Each has an unmistakable signature. Reproduced with copies of the team's package:

```bash
cp -R lab/bundle-team-orders lab/bundle-noca;   sed -i.bak '/ssl.truststore/d' lab/bundle-noca/client.properties
cp -R lab/bundle-team-orders lab/bundle-nocert; sed -i.bak '/ssl.keystore/d'   lab/bundle-nocert/client.properties
```

**D1 — the client does not trust the CA** (forgot `ssl.truststore.*`):

```bash
lab/scripts/kafka-client.sh lab/bundle-noca kafka-topics.sh "${BS[@]}" --list
```

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_unknown) PKIX path building failed: ... unable to find valid certification path to requested target
```

**D2 — the client presents no certificate** (forgot `ssl.keystore.*`; the listener requires mTLS):

```bash
lab/scripts/kafka-client.sh lab/bundle-nocert kafka-topics.sh "${BS[@]}" --list
```

```text
Caused by: javax.net.ssl.SSLHandshakeException: (certificate_required) Received fatal alert: certificate_required
```

**D3 — only the bootstrap resolves in DNS** (they forgot the per-broker records):

```bash
HOSTS=bootstrap lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-broker-api-versions.sh --bootstrap-server bootstrap.kafka.lab.test:443 --command-config client.properties
```

```text
WARN [LegacyAdminClient clientId=admin-1] Error connecting to node broker-1.kafka.lab.test:443 (id: 1 rack: null isFenced: false)
java.net.UnknownHostException: broker-1.kafka.lab.test: Try again
```

(Pocket summary: **PKIX** = trust · **certificate_required** = identity · **UnknownHost** = DNS ·
**No subject alternative DNS name** = SAN · **TimeoutException after the bootstrap** = advertised address.)

### Scenario E — Renewing the certificate without dropping anyone

What scares people most about their own TLS: *"what happens when it expires?"* cert-manager renews by itself
(here, 30 days before expiry) and Strimzi propagates it. To prove there is **no downtime**, run a continuous
producer (`acks=all`, 20 msg/s) and force a renewal in the middle:

```bash
lab/scripts/kafka-client.sh lab/bundle-team-orders kafka-producer-perf-test.sh --topic orders.events --num-records 5000 \
  --record-size 200 --throughput 20 --command-config client.properties \
  --producer-props bootstrap.servers=bootstrap.kafka.lab.test:443 acks=all delivery.timeout.ms=60000      # terminal 1
```

```bash
kx -n kafka patch certificate kafka-external --type merge -p '{"spec":{"renewBefore":"2159h59m"}}'         # terminal 2
kx apply -f lab/manifests/10-pki.yaml                                                                       # puts renewBefore=720h back
EXPECT_ROLL=1 lab/scripts/wait-kafka.sh
```

```text
serial before: 65456FF50322304EEC9CE7AC4C16ABED83BBC2C1
serial after:  7087F78A614EDE7C197E232A62A81B8545D2366C         # new certificate, NEW key (rotationPolicy: Always)
kafka ready (3/3 brokers, quiet for 47s)                         # renewal → 3 brokers restarted and stable: 155 s
```

The producer's result (in terminal 1):

```text
5000 records sent, 19.998800 records/sec (0.00 MB/sec), 12.04 ms avg latency, 512.00 ms max latency, 11 ms 50th, 15 ms 95th, 36 ms 99th, 242 ms 99.9th.
WARN [Producer clientId=perf-producer-client] Received invalid metadata error in produce request on partition orders.events-1 due to ...NotLeaderOrFollowerException
```

**5000 of 5000 records delivered**, maximum latency 512 ms, and only **2 warnings** of `NotLeaderOrFollower` (the
broker restarted and the leader moved; the client resent on its own). This holds **because** replication is 3,
`min.insync.replicas=2` and Strimzi restarts **one broker at a time**, waiting for it to be ready. Clients keep
working because the **CA is the same** — only the leaf certificate changed. (Changing the **CA** is a different
operation: then the teams must receive the new CA *first* — that is what trust-manager is for.)

## 9. Going to production

| Lab | Production |
|---|---|
| Envoy `Service` as `NodePort` + kind `extraPortMappings` | a **`LoadBalancer`** `Service` (Envoy Gateway creates it for you if you remove the `envoyService` block); DNS points to its IP/hostname. With `externalTrafficPolicy: Local` (what Envoy Gateway used here) the LB health-checks which nodes run Envoy and preserves the client IP |
| `Gateway` in the `kafka` namespace, `allowedRoutes: Same` | `Gateway` in an **infrastructure** namespace, `allowedRoutes.namespaces` by *selector*, 2+ Envoy replicas, `PodDisruptionBudget`, resource and connection limits (`maxConnections` on the listener) |
| **Self-signed** root CA, in the cluster | **Corporate CA** (internal PKI, Vault, AWS Private CA, Venafi…) as a cert-manager `Issuer`; root **offline**, an intermediate for the cluster |
| dnsmasq + CoreDNS `rewrite` | a real zone (Route 53 / Cloud DNS) with records (or a wildcard) for the bootstrap and each broker; ExternalDNS if you want to automate it |
| Explicit SAN (bootstrap + 3 brokers) | decide **wildcard × explicit** with security; with explicit, **scaling the cluster requires reissuing the certificate first** (scenario B) |
| 90-day certificate, renews 30 before | same, but **alert** on expiry (`certmanager_certificate_expiration_timestamp_seconds`) and on pods in `CrashLoopBackOff` (scenario C) |
| `keystore.pem` handed over "by hand" | deliver through a **vault/secret manager**; for in-cluster apps, `KafkaAccess` (Day 5); define identity **rotation and revocation** |
| Per-team mTLS with prefix ACLs | + **quotas** (`KafkaUser`), `networkPolicyPeers` on the listener, observability of the Gateway and the brokers (Day 10) |

## 10. Gotchas the lab hit

1. **The handshake "connects and hangs" with Envoy Gateway on NodePort.** Envoy Gateway creates the `Service`
   with `externalTrafficPolicy: Local`: a node only answers if an Envoy pod runs **on it**. kind publishes 443 on
   the *control-plane* node (where Envoy does not run), so TCP connects and TLS never gets an answer (`SSL
   connection timeout`). In a cloud, the LB does health checks and this does not show; in the lab,
   `externalTrafficPolicy: Cluster` in the `EnvoyProxy` fixes it. Diagnostic hint: `openssl s_client` works
   **from inside the node** and fails from outside.
2. **Changing the certificate restarts the cluster, and Strimzi only notices after ~1 min.** Plan windows and
   do not worry about "nothing happens" right after the issue.
3. **`privateKey.encoding` alone does not reissue the certificate** in cert-manager; combine it with a renewal.
4. **Kafka stays `Ready=True` with a broker in `CrashLoopBackOff` because of an invalid key** (scenario C).
5. **Port 5353 on macOS** belongs to mDNSResponder: the lab's dnsmasq uses **5354**.
6. **Strimzi 1.3.x requires Kubernetes ≥ 1.32**; the default `kindest/node` of an older `kind` is 1.31.
7. **An expensive *shell* mistake:** `[ "$n" = 3 ]` with `n=$(… | wc -w)` fails on macOS because `wc` pads with
   spaces. Use numeric comparison (`$((n))`) in wait scripts — `wait-kafka.sh` does.

## 11. Suggested video script

Target length: **~25 min**. The thread is the sentence "the bootstrap connects, everything else times out".

| Time | Block | What to show |
|---|---|---|
| 0:00 | Hook | "I connect to the bootstrap, `--list` works, and producing times out. Why?" |
| 1:30 | How the client connects | Section 1: the 3 stages; `advertised.listeners` |
| 4:00 | Listener types | The section 2 table; **`ingress` deprecated → `tlsroute`**; the SNI trick |
| 8:00 | Which one / Istio | Section 3; discussions #11869 and #12200; the OpenShift Router (`route`) |
| 10:30 | The 3 chains of trust | Section 4: Cluster CA × Clients CA × listener certificate |
| 12:00 | Lab: DNS and PKI | `dns-local.sh`, `dns-cluster.sh`; `10-pki.yaml` (SAN, PKCS8) |
| 14:30 | Gateway + Kafka `tlsroute` | The TLSRoutes Strimzi created; `openssl s_client` with `-servername` |
| 16:30 | A team connects | `client-bundle.sh`; mTLS; ACL denying the other team's topic; trust-manager |
| 19:30 | **Scenario A** | `nodeport` without `advertisedHost`: metadata with `172.18.0.x` IPs |
| 21:30 | **Scenarios B and C** | Missing SAN; PKCS#1 key → `CrashLoopBackOff` with Kafka `Ready` |
| 23:30 | **Scenario E** | Rotation with a producer running: 5000/5000, 155 s |
| 24:30 | Closing | The section 9 checklist; teaser for the next Day |

## 12. What this lab does NOT cover (honestly)

- **A real `loadbalancer`:** on kind/Docker Desktop a `LoadBalancer` has no IP reachable from the laptop.
  Described in the section 2 table; **not executed**.
- **`route` (OpenShift Router) and `ingress` (deprecated):** described by Strimzi's documentation and the CRD;
  **not executed** (there is no OpenShift here, and `ingress` depends on NGINX Ingress, retired).
- **Istio:** only the two discussions; **nothing was reproduced in this lab**.
- **The `/etc/resolver/lab.test` file and `/etc/hosts` were not applied on the host** (they need `sudo`).
  dnsmasq was validated with `dig` directly; resolution through the operating system was **not exercised**.
  All client tests ran in a **container** (`kafka-client.sh` maps the names to the host). A native `kcat` on
  macOS (librdkafka 2.15.0) **failed** against the plaintext `nodeport` listener — not diagnosed; the same test
  with the Java client and with `kcat` 1.7.1 in a container worked.
- **SCRAM / OAuth on the external listener:** the lab uses mTLS only. Switching is
  `authentication: scram-sha-512` (Day 4).
- **Rotation of Strimzi's Clients CA/Cluster CA** and **revocation** of client certificates: not exercised.
- **Multiple clusters / network peering**, **Windows**, **IPv6**, **load** (throughput through the Gateway was not measured).
- The timings (~60 s for Strimzi to notice the `Secret`, ~155 s for a rotation) were measured on Docker
  Desktop (Apple Silicon) and vary in your environment.

## 13. Cleanup

```bash
kind delete cluster --name strimzi-day11
lab/scripts/dns-local.sh down            # and: sudo rm -f /etc/resolver/lab.test   (or the /etc/hosts line)
rm -rf lab/bundle-*                       # teams' private keys: do not leave them lying around
```

## 14. References

- Strimzi — [Accessing Kafka using Gateway API `TLSRoute` resources](https://strimzi.io/docs/operators/latest/deploying.html) and the
  *Configuring listeners* / *Installing your own listener certificates* (`brokerCertChainAndKey`) chapters of the official documentation.
- Strimzi discussions about Istio: [#11869](https://github.com/orgs/strimzi/discussions/11869) and [#12200](https://github.com/orgs/strimzi/discussions/12200).
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) (`Gateway`, `TLSRoute`) and [Envoy Gateway](https://gateway.envoyproxy.io/).
- [cert-manager](https://cert-manager.io/) (`Certificate`, `ClusterIssuer`, `privateKey.encoding`, `renewBefore`) and [trust-manager](https://cert-manager.io/docs/trust/trust-manager/) (`Bundle`).
- Day 4 (authentication, mTLS and ACLs), Day 5 (KafkaAccessOperator) and Day 10 (observability) of this repository.
