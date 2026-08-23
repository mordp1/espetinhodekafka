# Cruise Control on Strimzi — Introduction and Deploy

> **Goal:** introduce **Cruise Control** — the same tool LinkedIn built to operate Kafka at
> scale, now embedded in Strimzi as a Custom Resource — without running any real
> rebalancing task yet. This Day is **conceptual and deploy-only**: what Cruise Control is,
> why it exists, how Strimzi integrates it, and how to confirm it's actually running in your
> cluster. The hands-on part — generating real load, requesting a rebalance proposal,
> approving and executing it, scaling up/down safely, self-healing, and the full goal
> catalog — is [Day 7](../Day7-CruiseControl-Avancado/), on purpose: you should only put
> your hands on a tool that moves production partitions after understanding what it is.

---

## Table of Contents

1. [Context](#1-context)
2. [What Is Cruise Control](#2-what-is-cruise-control)
3. [Prerequisites](#3-prerequisites)
4. [Lab Structure](#4-lab-structure)
5. [Bringing Up the Kind Cluster](#5-bringing-up-the-kind-cluster)
6. [Installing the Strimzi Cluster Operator](#6-installing-the-strimzi-cluster-operator)
7. [Deploy: Kafka + Node Pools + Cruise Control](#7-deploy-kafka--node-pools--cruise-control)
8. [Goals: Overview (Hard vs Soft)](#8-goals-overview-hard-vs-soft)
9. [Cleanup](#9-cleanup)
10. [What's Next: Day 7](#10-whats-next-day-7)
11. [References](#11-references)

---

## 1. Context

In [Day 2](../Day2-NodePools/) we scaled a `KafkaNodePool` with `kubectl scale` and the new
broker just sat there, empty — no existing partition moved onto it. In
[Day 3](../Day3-NodePools-Avancado/), we tried removing a specific broker via
`strimzi.io/remove-node-ids` and Strimzi **refused** because that node still had partition
replicas assigned — we had to manually pick an "empty" node to remove instead.

Both situations point to the same gap: **neither Strimzi nor Kafka moves data
automatically when the cluster topology changes.** Scaling doesn't rebalance. Shrinking
requires you (or some tool) to have already emptied the broker beforehand. In production,
doing this by hand with `kafka-reassign-partitions.sh` is tedious, risky, and doesn't
account for network/disk throughput while moving data — you decide by hand which replicas
to move, in what order, with no real visibility into how much CPU/disk/network each broker
is already using. That's exactly the gap **Cruise Control** closes.

This Day stays at the introduction level: what the tool is, how it thinks, and how it shows
up on your cluster as soon as you flip the CR on. Actually getting your hands dirty —
generating load, requesting a proposal, approving it, scaling safely — is
[Day 7](../Day7-CruiseControl-Avancado/).

## 2. What Is Cruise Control

[Cruise Control](https://github.com/linkedin/cruise-control) is an autonomous operations
system for Kafka, created by LinkedIn and now maintained as
an independent open source project at
[cruise-control-for-kafka/cruise-control](https://github.com/cruise-control-for-kafka/cruise-control)
(the active fork that carried the original LinkedIn project forward). Internally it's split
into four components running in a continuous pipeline:

```
Metrics Reporter (on the brokers)
        │  publishes metrics to internal topics
        ▼
  Load Monitor  ──►  Analyzer  ──►  Anomaly Detector  ──►  Executor
  (builds the        (applies       (detects goal          (actually moves
   cluster's load      goals and     violations, broker/     replicas, with
   model)              generates     disk failure, etc. —    controlled
                       the            triggers self-          throttling and
                       proposal)      healing)                concurrency)
```

- **Load Monitor** — consumes metrics (CPU, disk, per-partition bytes-in/out, replica size)
  published by the Metrics Reporter plugged into the brokers and builds a **cluster load
  model** over sampling windows.
- **Analyzer** — from that model, computes **optimization proposals**: which replicas to
  move, from which broker to which broker, to satisfy an ordered set of **goals**
  (section 8).
- **Anomaly Detector** — continuously watches the cluster for anomalies (broker down, disk
  failed, a goal was violated) and, if self-healing is enabled for that type, triggers the
  Executor automatically ([Day 7](../Day7-CruiseControl-Avancado/)).
- **Executor** — actually moves the data, respecting configurable concurrency limits and
  network/disk throttling ([Day 7](../Day7-CruiseControl-Avancado/)).

All of this state — metric samples, the trained load model, proposal results — is
persisted in **three internal topics** that Strimzi itself creates when you enable Cruise
Control: `strimzi.cruisecontrol.metrics`, `strimzi.cruisecontrol.modeltrainingsamples`, and
`strimzi.cruisecontrol.partitionmetricsamples`. This matters in practice: if you delete
those topics manually or zero out their retention, Cruise Control loses its history and
goes back to asking you to "wait for the sampling windows" (the
[original Strimzi blog post on Cruise Control](https://strimzi.io/blog/2020/06/15/cruise-control/)
explains this continuous-sampling mechanic well).

Strimzi **doesn't package** Cruise Control as a separate binary you install and configure
yourself (it doesn't require the manual `capacityJBOD.json` the upstream project asks for
either) — it's a first-class Custom Resource:

| Custom Resource | What it's for |
|---|---|
| `Kafka.spec.cruiseControl` | Turns Cruise Control on for the cluster — the operator deploys it, injects the Metrics Reporter into the brokers, creates the internal metrics topics, and **derives disk capacity automatically** from the `KafkaNodePool` volume sizes (upstream requires a manual JSON for this) |
| `KafkaRebalance` | Requests a rebalance proposal (or triggers its execution) — the central object of [Day 7](../Day7-CruiseControl-Avancado/) |

> **Why this matters in production:** rebalancing "by hand" with
> `kafka-reassign-partitions.sh` means you decide which replicas to move and in what order
> yourself, with no real sense of how much disk/network/CPU each broker is already using —
> it's easy to saturate the cluster's network by moving too much data at once, or to move a
> replica to the wrong broker and make the imbalance worse. Cruise Control solves this with
> built-in data-movement throttling and goals that see the whole cluster at once. The
> [Red Hat Streams for Apache Kafka docs](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str)
> summarize this same rationale well in KRaft mode: Cruise Control continuously monitors
> disk, CPU, and network load and uses that to decide *what* to move, not just *that*
> something needs moving.

## 3. Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with at least ~6GB of free RAM (4 kind
  nodes + Cruise Control + Kafka running at the same time)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Having done [Day 2](../Day2-NodePools/) and [Day 3](../Day3-NodePools-Avancado/) (we
  assume you've already scaled a `KafkaNodePool` and seen Strimzi refuse an unsafe
  scale-down — that's exactly the pain Cruise Control solves)

## 4. Lab Structure

```
Day6-CruiseControl/
├── kind-config.yaml                  # kind cluster: 1 control-plane + 3 workers
├── kafka-nodepool-controller.yaml    # KafkaNodePool "controller" (3 replicas)
├── kafka-nodepool-broker.yaml        # KafkaNodePool "broker" (3 replicas, 10Gi)
├── kafka-cluster.yaml                # Kafka CR with cruiseControl enabled
├── README.md
└── README-EN.md
```

No workload, no `KafkaRebalance` — this Day only brings up the cluster and shows Cruise
Control alive. The multi-topic workload manifests and the three `KafkaRebalance` modes
(`full`, `add-brokers`, `remove-brokers`) used to live here, but now live in
[Day 7](../Day7-CruiseControl-Avancado/), together with the rest of the hands-on flow.

## 5. Bringing Up the Kind Cluster

We use **3 workers** in this Day (instead of 2, like Days 2/3) to already leave the
environment ready for [Day 7](../Day7-CruiseControl-Avancado/), which needs that extra room
to scale from 3 to 4 brokers:

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day6
kubectl get nodes -o wide
```

## 6. Installing the Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 7. Deploy: Kafka + Node Pools + Cruise Control

The only difference in this lab's [`kafka-cluster.yaml`](kafka-cluster.yaml) compared to
Day 2 is the `cruiseControl` block:

```yaml
spec:
  # ...listeners, config, entityOperator same as Day 2...
  cruiseControl:
    config:
      self.healing.broker.failure.enabled: "true"
```

That's all you need in the `Kafka` CR — Strimzi handles the rest (Cruise Control
deployment, RBAC, internal metrics topics, configuring the Metrics Reporter on the
brokers). That's literally the difference between "installing and configuring plain
Cruise Control" (which the
[official Strimzi deploying docs](https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str)
describe in more detail) and just flipping a switch on a CR you already have.

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
kubectl get pods -n kafka
```

Besides the broker/controller pods, you should see one extra pod:

```
my-cluster-cruise-control-<hash>   1/1   Running
```

That pod is the complete Cruise Control — Load Monitor, Analyzer, Anomaly Detector, and
Executor all running inside it, sampling metrics from the first second, even with no
`KafkaRebalance` applied yet. Confirm it's actually collecting state:

```bash
kubectl logs -n kafka deployment/my-cluster-cruise-control --tail=20
kubectl get kafkatopic -n kafka
```

Notice the three internal topics created automatically
(`strimzi.cruisecontrol.metrics`, `strimzi.cruisecontrol.modeltrainingsamples`,
`strimzi.cruisecontrol.partitionmetricsamples`) — that's the Load Monitor already at work,
even with no rebalancing task requested yet.

> **A security detail that flies under the radar:** the Cruise Control REST API exposes
> potentially destructive operations (decommissioning a broker, bulk replica moves). That's
> why Strimzi deploys Cruise Control with **HTTP Basic Auth + TLS enabled by default** and
> automatically creates two internal users — `admin` (used by the operator itself to
> orchestrate rebalances) and `healthcheck` (used only for the readiness probe). You won't
> need to touch this directly (everything happens through `KafkaRebalance`), but it's worth
> knowing the API isn't left open without authentication — unlike many "plain" (non-Strimzi)
> Cruise Control tutorials (like the one [Axual walks through in detail](https://axual.com/blog/apache-kafka-cruise-control))
> that sometimes run the API with no protection at all in a demo.

## 8. Goals: Overview (Hard vs Soft)

Still without running anything — just so you leave this Day already knowing *how Cruise
Control thinks* before you see it in action in Day 7. Every optimization proposal is
computed against an ordered list of **goals**. Order matters: the Analyzer processes the
list top to bottom, prioritizing earlier goals when two goals conflict. Each goal falls
into one of two categories, **fixed in Cruise Control's code** (you can't reclassify a goal
from hard to soft):

- **Hard goals** — the Analyzer **must include** these goals when computing the proposal.
  If a hard goal can't be satisfied, the whole proposal fails (unless you use
  `skipHardGoalCheck: true` — see Day 7, and understand the risk before using it).
- **Soft goals** — optimized as best as possible, but they don't block the proposal if they
  aren't 100% satisfied.

A common subset of goals, in the priority order Cruise Control uses by default:

| Goal | Hard/Soft | What it does |
|---|---|---|
| `RackAwareGoal` | Hard | Ensures a partition's replicas land in different racks/zones |
| `ReplicaCapacityGoal` | Hard | No broker gets more replicas than the configured limit |
| `DiskCapacityGoal` | Hard | No broker exceeds disk capacity (80% by default — see Day 7) |
| `NetworkInboundCapacityGoal` / `NetworkOutboundCapacityGoal` | Hard | No broker exceeds the configured network capacity |
| `CpuCapacityGoal` | Hard | No broker exceeds the configured CPU capacity |
| `ReplicaDistributionGoal` | Soft | Distributes replica **count** evenly across brokers |
| `DiskUsageDistributionGoal` | Soft | Distributes **disk bytes** evenly across brokers |
| `NetworkInboundUsageDistributionGoal` / `NetworkOutboundUsageDistributionGoal` | Soft | Distributes network usage evenly |
| `CpuUsageDistributionGoal` | Soft | Distributes CPU usage evenly |
| `TopicReplicaDistributionGoal` | Soft | Distributes replicas **per topic** evenly (not just the aggregate) |
| `LeaderReplicaDistributionGoal` | Soft | Distributes partition **leadership** evenly (whoever leads is who actually eats the I/O load) |

> **A real production gotcha — a hook for Day 7:** "hard goal" **does not mean** "goal that
> must be satisfied." It means "goal that must be **executed**" during proposal
> computation. This is a documented misunderstanding even within the Strimzi community
> itself (plenty of people configure only `RackAwareGoal` as a hard goal and are surprised
> when the proposal fails on `NetworkInboundCapacityGoal`, which they never declared at
> all). The mechanics of `default.goals`/`hard.goals`/`self.healing.goals`, plus a real case
> where this brought down an entire proposal because the default network capacity (10MB/s)
> was too low for the actual traffic, come with full detail in
> [Day 7](../Day7-CruiseControl-Avancado/#8-catálogo-completo-de-goals-hard-vs-soft).

Omitting `spec.goals` on a `KafkaRebalance` uses the cluster's
`cruiseControl.config.default.goals` (which by default includes a longer list — see Day 7).
A good talk to pair with this overview, from the people who maintain the project, is the
[Kafka Summit London 2023 introduction to Cruise Control](https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/).

## 9. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # should disappear on their own thanks to deleteClaim: true
kind delete cluster --name strimzi-day6
```

> Since this Day doesn't create any `KafkaTopic` or `KafkaRebalance`, the deletion order
> doesn't have the stuck-finalizer trap that shows up once topics are involved (see
> [Day 7](../Day7-CruiseControl-Avancado/) for that caveat, relevant from the moment you
> start creating real topics).

## 10. What's Next: Day 7

This Day covered the introduction: what Cruise Control is, why it exists, how it thinks
(goals), and how to confirm it's up on your cluster. Actually getting your hands dirty is
**[Day 7 — Cruise Control Advanced](../Day7-CruiseControl-Avancado/)**, which covers —
all with real commands, tested end to end:

- A **realistic multi-topic workload** to have something real to rebalance.
- The three manual `KafkaRebalance` modes — **`full`** (proposal → approval → execution),
  **`add-brokers`** (scaling safely), and **`remove-brokers`** (shrinking without Strimzi
  refusing the scale-down, like it almost did in Day 3).
- Broker-failure **self-healing** (and the caveat about `kubectl delete pod` vs. a real
  failure).
- The **complete catalog** of goals and the real `hard.goals` gotcha.
- Real **capacity planning**: `brokerCapacity`, per-broker overrides, and two documented
  bugs that silently sink proposals (1-core CPU default, and a network default that's too
  low).
- **Incident-scoped custom goals**, **intra-broker (JBOD) rebalancing**, **performance
  tuning/throttling**, the **5 self-healing anomaly types**, `autoRebalance`, REST API
  security, and an honest section on Cruise Control's **architectural limits**.
- A **complete incident scenario**, simulating a full disk in production from start to
  finish.

## 11. References

| Resource | URL |
|---|---|
| Strimzi — Cruise Control for cluster rebalancing (deploy) | https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str |
| Strimzi — Blog: Cruise Control (original introduction, 2020) | https://strimzi.io/blog/2020/06/15/cruise-control/ |
| Red Hat — Streams for Apache Kafka (KRaft): Cruise Control concepts | https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str |
| Axual — Apache Kafka Cruise Control (practical overview) | https://axual.com/blog/apache-kafka-cruise-control |
| Confluent — Kafka Summit London 2023: An Introduction to Kafka Cruise Control | https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/ |
| Cruise Control — repository (active fork, post-LinkedIn) | https://github.com/cruise-control-for-kafka/cruise-control |
| Strimzi — KafkaRebalance API Reference | https://strimzi.io/docs/operators/latest/configuring#type-KafkaRebalance-reference |
| kind | https://kind.sigs.k8s.io/ |
| Release used in this lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Part of the **Espetinho de Kafka** series — Strimzi Day 6: Cruise Control (Introduction).
> Previous Day: [Kafka Access Operator](../Day5-KafkaAccessOperator/).
> Next Day: [Cruise Control Advanced](../Day7-CruiseControl-Avancado/).
