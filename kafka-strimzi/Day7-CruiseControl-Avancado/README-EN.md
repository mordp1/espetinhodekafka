# Cruise Control Advanced — Rebalancing in Practice, Goals, Capacity Planning, JBOD and Full Automation

> **Goal:** move past the theory from [Day 6](../Day6-CruiseControl/) — what Cruise Control
> is and how it thinks — and **actually get your hands dirty**: generate realistic load,
> request a rebalance proposal, approve and execute it, scale the cluster up and down
> safely, and then go beyond the basic flow into what separates "I ran a `KafkaRebalance`
> once" from "I trust Cruise Control enough to let it make decisions on its own in
> production": the full goal catalog and its gotchas, real capacity planning, intra-broker
> JBOD rebalancing, performance tuning, the five self-healing anomaly types, full
> automation via `autoRebalance`, API security, and — just as important — the
> architectural limits Cruise Control does **not** solve. Every command in this Day was run
> end to end (including a `kind delete cluster` followed by a full re-run from scratch)
> before being documented here — the caveats marked "reproduced in this lab" are real bugs
> that showed up during that testing, not hypotheticals.

---

## Table of Contents

1. [Context](#1-context)
2. [Prerequisites](#2-prerequisites)
3. [Lab Structure](#3-lab-structure)
4. [Bringing Up the Kind Cluster](#4-bringing-up-the-kind-cluster)
5. [Installing the Strimzi Cluster Operator](#5-installing-the-strimzi-cluster-operator)
6. [Deploy: Kafka + JBOD Node Pools + Advanced Cruise Control](#6-deploy-kafka--jbod-node-pools--advanced-cruise-control)
7. [Modeling a Realistic Workload (Multi-Topic)](#7-modeling-a-realistic-workload-multi-topic)
8. [Full Rebalance: Proposal, Approval, Execution](#8-full-rebalance-proposal-approval-execution)
9. [Scaling Safely: `add-brokers`](#9-scaling-safely-add-brokers)
10. [Shrinking Safely: `remove-brokers`](#10-shrinking-safely-remove-brokers)
11. [Full Goal Catalog (Hard vs Soft)](#11-full-goal-catalog-hard-vs-soft)
12. [Capacity Planning: `brokerCapacity` and the "1 Core" and Network Bugs](#12-capacity-planning-brokercapacity-and-the-1-core-and-network-bugs)
13. [Incident-Scoped Custom Goals](#13-incident-scoped-custom-goals)
14. [Intra-Broker (JBOD) Rebalancing](#14-intra-broker-jbod-rebalancing)
15. [Performance Tuning: Concurrency and Throttling](#15-performance-tuning-concurrency-and-throttling)
16. [Full Self-Healing: the 5 Anomaly Types](#16-full-self-healing-the-5-anomaly-types)
17. [Full Automation: `autoRebalance`](#17-full-automation-autorebalance)
18. [Cruise Control REST API Security](#18-cruise-control-rest-api-security)
19. [Known Production Issues](#19-known-production-issues)
20. [Cruise Control's Architectural Limits](#20-cruise-controls-architectural-limits)
21. [Complete Scenario: Full Disk at 3 AM](#21-complete-scenario-full-disk-at-3-am)
22. [Cleanup](#22-cleanup)
23. [References](#23-references)

---

## 1. Context

[Day 6](../Day6-CruiseControl/) introduced Cruise Control — what it is, its four internal
components (Load Monitor, Analyzer, Anomaly Detector, Executor), and how Strimzi integrates
it as a Custom Resource — but stayed at the introduction level, without generating load or
running any `KafkaRebalance`. This Day is where the theory becomes practice, and where the
practice becomes depth: we start with the basic operational flow (real workload, the three
manual `KafkaRebalance` modes — `full`, `add-brokers`, `remove-brokers` — and broker-failure
self-healing) and go all the way to the questions that separate "I used Cruise Control
once" from someone who actually understands the tool:

- Why did a proposal with only `RackAwareGoal` as a hard goal fail because of
  `NetworkInboundCapacityGoal`, which wasn't even declared?
- Why does `CpuCapacityGoal` sometimes recommend "add 3 brokers" on a cluster that's
  barely being used?
- How do you fix **a full disk inside a single broker** — not between brokers, but
  between the JBOD disks of the same broker?
- How do you keep a rebalance from "hanging" for hours because of a parameter that looked
  harmless?
- How many failure types does self-healing actually cover beyond "broker went down"?
- Can you remove the manual step of approving a `KafkaRebalance` every time you scale the
  cluster?
- And, with technical honesty: **what does Cruise Control not solve**, even when well
  configured?

This Day answers all of them — with its own cluster (JBOD, capacity planning configured,
more complete self-healing) and a multi-topic workload designed specifically to create
real, heterogeneous imbalance.

## 2. Prerequisites

- Having done [Day 6](../Day6-CruiseControl/) (what Cruise Control is, its architecture,
  a goal overview) and [Day 2](../Day2-NodePools/)/[Day 3](../Day3-NodePools-Avancado/)
  (basic and advanced `KafkaNodePool`) — this Day assumes you already understand the
  problem Cruise Control solves, you just haven't put your hands on it yet.
- [Docker](https://docs.docker.com/get-docker/) with at least ~7GB of free RAM (this Day's
  JBOD storage uses two PVCs per broker instead of one)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)

> **Resource note, observed testing this Day end to end:** with several heavy operations
> in a row (multi-topic load, JBOD, rebalances) running for hours on a laptop, the
> `strimzi-cluster-operator` itself can crash-loop from losing leader election under CPU
> pressure (`Stopped being a leader => exiting` in the log) — it recovers on its own
> (Kubernetes restarts the pod, and it resumes reconciling where it left off), but this
> leaves `KafkaRebalance` objects stuck longer than usual. If something looks "stuck" for
> a long time, check `kubectl get pods -n kafka -l name=strimzi-cluster-operator` before
> assuming it's a YAML bug.

## 3. Lab Structure

```
Day7-CruiseControl-Avancado/
├── kind-config.yaml                       # kind cluster: 1 control-plane + 3 workers
├── kafka-nodepool-controller.yaml         # KafkaNodePool "controller" (3 replicas)
├── kafka-nodepool-broker.yaml             # KafkaNodePool "broker" — JBOD, 2 volumes/broker
├── kafka-cluster.yaml                     # Kafka CR: brokerCapacity + full self-healing + autoRebalance
├── kafka-topic-heavy.yaml                 # KafkaTopic "shop.events"
├── kafka-topics-workload.yaml             # 6 additional KafkaTopics — realistic load (section 7)
├── kafkarebalance-full.yaml               # KafkaRebalance mode=full
├── kafkarebalance-add-brokers.yaml        # KafkaRebalance mode=add-brokers
├── kafkarebalance-remove-brokers.yaml     # KafkaRebalance mode=remove-brokers
├── kafkarebalance-disk-incident.yaml      # custom goals + skipHardGoalCheck + excludedTopics
├── kafkarebalance-intra-broker.yaml       # mode=full, rebalanceDisk=true
├── kafkarebalance-remove-disks.yaml       # mode=remove-disks
├── kafkarebalance-throttled.yaml          # explicit, safe concurrency/throttle
├── kafkarebalance-autoscale-templates.yaml# templates used by autoRebalance
├── README.md
└── README-EN.md
```

## 4. Bringing Up the Kind Cluster

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day7
kubectl get nodes -o wide
```

## 5. Installing the Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploy: Kafka + JBOD Node Pools + Advanced Cruise Control

Two topology differences from Day 6 right away: [`kafka-nodepool-broker.yaml`](kafka-nodepool-broker.yaml)
now has **two JBOD volumes** per broker (a prerequisite for section 14), and
[`kafka-cluster.yaml`](kafka-cluster.yaml) configures `brokerCapacity`, three self-healing
types, and `autoRebalance`:

```yaml
spec:
  cruiseControl:
    config:
      self.healing.broker.failure.enabled: "true"
      self.healing.goal.violation.enabled: "true"
      self.healing.disk.failure.enabled: "true"
    brokerCapacity:
      cpu: "2"
      inboundNetwork: 200000KiB/s
      outboundNetwork: 200000KiB/s
      overrides:
        - brokers: [3]
          cpu: "4"
          inboundNetwork: 400000KiB/s
          outboundNetwork: 400000KiB/s
```

> **Why `inboundNetwork`/`outboundNetwork` aren't left at the default (10000KiB/s):** while
> testing this Day from scratch, we reproduced a `full-rebalance` proposal (section 8)
> failing permanently with `NetworkInboundCapacityGoal` because the load burst from
> section 7 exceeds the ~10MB/s-per-broker default — even on a local kind cluster. Full
> detail in section 12.

> **Why `autoRebalance` isn't in here yet:** it's only enabled in section 17, on purpose.
> We reproduced live what happens if it's already on from this initial deploy: on the
> first `kubectl scale kafkanodepool broker --replicas=4` (section 9), the Cluster
> Operator fires `add-brokers` on its own, automatically — and the manual
> `add-brokers`/`remove-brokers` demo from sections 9 and 10 never actually happens the
> way it's documented, because the operator already handled everything before you get to
> apply the manual `KafkaRebalance`. Doing the manual flow first, and only automating it
> afterward, is deliberate — that's how you understand what's being automated before you
> trust it blindly.

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
kubectl get pods -n kafka
kubectl get kafkanodepool broker -n kafka -o jsonpath='{.status.nodeIds}'; echo
```

Note down the real `nodeIds` of the `broker` node pool — we'll use them in sections 9, 12,
and 14 (the `brokerCapacity` override and `moveReplicasOffVolumes` assume broker `0`, which
is what this lab produces: the `controller` node pool gets the higher IDs, `[3,4,5]`, and
`broker` gets the lower ones, `[0,1,2]` — but **confirm the real NODEIDS**; using a
`controller` ID in a field expecting a broker fails with `IllegalArgumentException:
Some/all brokers specified don't exist`, reproduced in this lab).

## 7. Modeling a Realistic Workload (Multi-Topic)

Without real data and without heterogeneity between topics, any rebalance is irrelevant —
every broker starts out "empty" and equally balanced, and Cruise Control's proposal becomes
an act of faith ("trust that it works"). To actually see the Analyzer working, we need a
cluster with **real, heterogeneous imbalance** — exactly like a production cluster serving
several business domains at once.

[`kafka-topic-heavy.yaml`](kafka-topic-heavy.yaml) (topic `shop.events`, 12 partitions,
RF 3) already existed in this Day. In [`kafka-topics-workload.yaml`](kafka-topics-workload.yaml)
we add **6 more topics** deliberately designed to create different kinds of imbalance —
it's not just "more data," it's imbalance **from different causes**, which is the real
scenario you'll run into in production:

| Topic | Partitions | RF | Profile | Why it's here |
|---|---|---|---|---|
| `shop.events` | 12 | 3 | General / baseline | Browsing/cart events |
| `clickstream.raw` | 24 | 3 | 🔥 **Hot** | Most partitions + highest throughput of all — dominates disk and network on whoever hosts its replicas |
| `orders.created` | 6 | 3 | Compacted | `cleanup.policy=compact` — disk does **not** grow linearly with throughput; a direct contrast to the append-only topics |
| `payments.processed` | 6 | 3 | Critical, low volume | `min.insync.replicas=3` — protected more strictly, but deliberately low volume (the basis for `excludedTopics` in section 13) |
| `inventory.updates` | 8 | 2 | Heterogeneous RF | RF 2 (vs. RF 3 elsewhere) — Cruise Control handles mixed RF fine within the same cluster |
| `audit.logs` | 4 | 3 | Heavy due to **retention** | Few partitions, large messages, 30-day retention — gets heavy without high throughput |
| `notifications.push` | 6 | 3 | ❄️ **Cold** | Nearly idle — baseline contrast to `clickstream.raw` |

Apply the topics and generate real load with the `kafka-producer-perf-test.sh` bundled in
the Kafka image (lower `--num-records` if your laptop is struggling — what matters is the
**proportion** between topics, not the absolute volume):

```bash
kubectl apply -f kafka-topic-heavy.yaml -n kafka
kubectl apply -f kafka-topics-workload.yaml -n kafka

# shop.events — baseline (~500MB raw)
kubectl -n kafka run kafka-producer-shop -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic shop.events --num-records 500000 --record-size 1000 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# clickstream.raw — the hot topic (~1.2GB raw, max throughput)
kubectl -n kafka run kafka-producer-clickstream -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic clickstream.raw --num-records 3000000 --record-size 400 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# orders.created — moderate volume, compacted topic
# NOTE: kafka-producer-perf-test.sh has no key option, and a compacted topic REJECTS
# keyless messages (InvalidRecordException — reproduced in this lab). So we use
# kafka-console-producer.sh with parse.key=true here, generating
# "order-<id>:<payload>" lines via awk.
kubectl -n kafka run kafka-producer-orders -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bash -c '
awk "BEGIN{
  payload=\"\";
  for(i=0;i<500;i++) payload = payload \"x\";
  for(i=0;i<150000;i++) printf \"order-%d:%s\n\", (i%5000), payload;
}" | bin/kafka-console-producer.sh --topic orders.created \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 \
  --property parse.key=true --property key.separator=:
'

# payments.processed — deliberately low volume
kubectl -n kafka run kafka-producer-payments -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic payments.processed --num-records 80000 --record-size 400 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# inventory.updates — RF2
kubectl -n kafka run kafka-producer-inventory -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic inventory.updates --num-records 200000 --record-size 300 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# audit.logs — large messages, few records, long retention
kubectl -n kafka run kafka-producer-audit -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic audit.logs --num-records 40000 --record-size 3000 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# notifications.push — nearly idle
kubectl -n kafka run kafka-producer-notifications -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic notifications.push --num-records 5000 --record-size 200 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092
```

All told that's **66 partitions** and ~1.9GB raw before replication. Check the current
distribution before moving to section 8 — it's the "before" that lets you actually see the
"after":

```bash
kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
  --bootstrap-server my-cluster-kafka-bootstrap:9092
```

> **Wait a few minutes before requesting any proposal.** Cruise Control needs to accumulate
> at least one metrics sampling window (5 minutes by default on Strimzi) after this load
> finishes generating. Requesting a proposal too early is the most common cause of
> `NotEnoughValidWindows` — see section 8.

## 8. Full Rebalance: Proposal, Approval, Execution

`KafkaRebalance` works in two steps by design — the operator **never** moves data without
explicit approval, unless you opt into auto-approval (section 17):

```bash
kubectl apply -f kafkarebalance-full.yaml -n kafka
kubectl get kafkarebalance -n kafka -w
```

The object's `status.conditions` evolves like this:

```
PendingProposal  →  ProposalReady  →  (approve)  →  Rebalancing  →  Ready
```

> **Important caveat:** Cruise Control needs to accumulate **metrics sampling windows**
> before it can build a reliable load model (several windows of a few minutes each
> upstream by default — Strimzi shortens the window to 5 minutes). If you apply the
> `KafkaRebalance` right after the cluster turns `Ready` — or right after generating the
> load from section 7 — the `status` is likely to come back with a `NotEnoughValidWindows`
> error condition. That's not a bug — it's Cruise Control refusing to give a proposal based
> on insufficient data (the same kind of caution you want in a tool that moves production
> partitions). Wait a few minutes and force a retry:
>
> ```bash
> kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=refresh -n kafka --overwrite
> ```

Once the status turns `ProposalReady`, inspect the proposal summary before approving —
this is what you'd show in an infra PR before running it in production:

```bash
kubectl describe kafkarebalance full-rebalance -n kafka
```

The `status` carries an `Optimization Result` summary with bytes moved, number of replicas
relocated, and estimated change per goal. With the multi-topic load from section 7, expect
`clickstream.raw` to dominate the volume of bytes moved — that's exactly the expected
behavior of `DiskUsageDistributionGoal`/`NetworkInboundUsageDistributionGoal` trying to fix
the heaviest topic in the cluster. Approving:

```bash
kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance full-rebalance -n kafka -w
```

Once the status goes back to `Ready`, the rebalance is done — no downtime, no manual
reassignment math. Run the `kafka-topics.sh --describe` from section 7 again and compare
the distribution before/after.

> **Worth calibrating expectations here:** with RF 3 (or RF 2 for `inventory.updates`) on
> exactly 3 brokers, a lot of the replicas already exist on every broker by construction —
> the visible disk imbalance is smaller than you'd expect before running this. What this
> `full-rebalance` tends to fix more visibly is **leadership distribution**
> (`LeaderReplicaDistributionGoal`), not necessarily a large volume of bytes moved. The
> *dramatic* imbalance really shows up in section 9, when a genuinely empty new broker
> joins.

## 9. Scaling Safely: `add-brokers`

Scale the broker pool from 3 to 4, exactly like in [Day 2](../Day2-NodePools/):

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka
kubectl get kafkanodepool broker -n kafka
```

Confirm the new broker's `nodeId` in the `NODEIDS` column (it should be `6`, following the
same sequential numbering seen in Day 2 — but **confirm the real value** before the next
step). If it's different from `6`, adjust `kafkarebalance-add-brokers.yaml`.

Without Cruise Control, this new broker would stay **empty** forever — nothing forces
Kafka to move existing replicas onto it. `mode: add-brokers` fixes that: it asks Cruise
Control to move a fraction of the existing replicas specifically onto the listed brokers.
With 66 partitions spread across 7 heterogeneous topics (section 7), this is a much more
realistic scenario than "an empty cluster gaining a broker" — Cruise Control has to decide
*which* replicas of *which* topics to migrate without recreating the imbalance somewhere
else.

```bash
kubectl apply -f kafkarebalance-add-brokers.yaml -n kafka
kubectl annotate kafkarebalance add-brokers-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance add-brokers-rebalance -n kafka -w
```

> **Gotcha reproduced in this lab:** if you apply `add-brokers-rebalance` right after the
> new broker's pod turns `Ready` (without waiting for Cruise Control to absorb the new
> broker in at least one sampling window — in practice, about 5 minutes), the `status`
> comes back `NotReady` with a generic `NullPointerException` (`Cannot invoke
> "BrokerCapacityInfo.capacity()"...`) — the internal `capacity.json` already lists the new
> broker correctly (Strimzi derives its capacity on the spot), but Cruise Control's load
> model hasn't included it yet. This is **not fatal**: forcing a retry fixes it, the same
> way as `NotEnoughValidWindows` in section 8:
> ```bash
> kubectl annotate kafkarebalance add-brokers-rebalance strimzi.io/rebalance=refresh -n kafka --overwrite
> ```

Once `Ready`, confirm the new broker actually has replicas:

```bash
kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
  --bootstrap-server my-cluster-kafka-bootstrap:9092
```

## 10. Shrinking Safely: `remove-brokers`

Here's the direct contrast with [Day 3](../Day3-NodePools-Avancado/): there, we tried
manually removing a node with assigned replicas and Strimzi **reverted** the scale-down on
its own, as a safety net. `mode: remove-brokers` automates exactly the missing step —
emptying the broker **before** you reduce `replicas`:

```bash
kubectl apply -f kafkarebalance-remove-brokers.yaml -n kafka
kubectl annotate kafkarebalance remove-brokers-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance remove-brokers-rebalance -n kafka -w
```

Only once the `status` turns `Ready` (meaning broker `6` no longer has any replicas
assigned) is it safe to shrink the node pool:

```bash
kubectl scale kafkanodepool broker --replicas=3 -n kafka
```

Unlike the manual attempt in Day 3, here **there's no chance of Strimzi reverting the
scale-down** — Cruise Control has already guaranteed the condition that caused the
rejection (replicas assigned to the node) no longer exists before you even touch
`replicas`.

## 11. Full Goal Catalog (Hard vs Soft)

Day 6 showed a common subset of goals (the same one used in
[`kafkarebalance-full.yaml`](kafkarebalance-full.yaml), section 8). This is the complete
list of Cruise Control's `default.goals`, in the real priority order (the Analyzer
processes it top to bottom):

| # | Goal | Category | What it does |
|---|---|---|---|
| 1 | `RackAwareGoal` | Hard | Puts a partition's replicas in different racks/zones |
| 2 | `MinTopicLeadersPerBrokerGoal` | Hard | Guarantees a minimum number of leaders per broker for configured topics |
| 3 | `ReplicaCapacityGoal` | Hard | Maximum replica limit per broker |
| 4 | `DiskCapacityGoal` | Hard | No broker exceeds the disk **threshold** (80% of capacity — not 100%, see below) |
| 5 | `NetworkInboundCapacityGoal` | Hard | No broker exceeds the inbound network threshold (80%) |
| 6 | `NetworkOutboundCapacityGoal` | Hard | No broker exceeds the outbound network threshold (80%) |
| 7 | `CpuCapacityGoal` | Hard | No broker exceeds the CPU threshold (**70%**, the most aggressive of all) |
| 8 | `ReplicaDistributionGoal` | Soft | Distributes replica count across brokers |
| 9 | `PotentialNwOutGoal` | Soft | Prevents a broker failure from overloading the others' network when reassigning leadership |
| 10 | `DiskUsageDistributionGoal` | Soft | Distributes disk bytes across brokers |
| 11 | `NetworkInboundUsageDistributionGoal` | Soft | Distributes inbound network usage |
| 12 | `NetworkOutboundUsageDistributionGoal` | Soft | Distributes outbound network usage |
| 13 | `CpuUsageDistributionGoal` | Soft | Distributes CPU usage |
| 14 | `TopicReplicaDistributionGoal` | Soft | Distributes replicas **per topic** (not just the aggregate) |
| 15 | `LeaderReplicaDistributionGoal` | Soft | Distributes partition leadership |
| 16 | `LeaderBytesInDistributionGoal` | Soft | Distributes the bytes-in each broker receives **as leader** |

Outside this default list there are the intra-broker rebalancing goals
(`IntraBrokerDiskCapacityGoal`, `IntraBrokerDiskUsageDistributionGoal` — section 14) and the
legacy `KafkaAssignerDiskUsageDistributionGoal`, which aren't part of `default.goals`.

**The thresholds matter more than they look:** a "capacity" goal doesn't trigger at 100%
usage — it triggers at `disk.capacity.threshold` (0.8), `cpu.capacity.threshold` (0.7), or
`network.{inbound,outbound}.capacity.threshold` (0.8). That means a broker at **71% CPU**
is already, technically, a `CpuCapacityGoal` violation. This is intentional (you want
headroom before hitting the real limit), but it surprises people reading
`kubectl describe kafkarebalance` for the first time and seeing "capacity goal violated" on
a broker that "doesn't look that full."

### The goal hierarchy nobody reads until it bites them

```
hard.goals          ⊆  default.goals   ⊆  goals (everything on the classpath)
hard.goals          ⊆  self.healing.goals
anomaly.detection.goals  (a subset of self.healing.goals — defines what counts as a "goal violation")
```

- `default.goals` — used when a `KafkaRebalance` **doesn't** declare `spec.goals`.
- `hard.goals` — the goals **every** proposal must execute, custom or not.
- `self.healing.goals` — used when the Anomaly Detector triggers automatic self-healing
  (must be a superset of `hard.goals`, or self-healing simply can't fix the anomaly).
- `anomaly.detection.goals` — defines which goal violations count as an "anomaly" for
  goal-violation self-healing (section 16) to react to.

> **The real production gotcha:** "hard goal" **does not mean** "goal that must be
> satisfied" — it means "goal that must be **executed**" during proposal computation. This
> is a documented misunderstanding even within the Strimzi community: someone configured
> only `RackAwareGoal` as a hard goal, expecting only it to be mandatory, and the proposal
> failed with `"Insufficient capacity for networkInbound"` — a goal they never declared as
> hard. A maintainer's explanation was direct: *"the `hard.goals` config is NOT a list of
> goals 'that must be satisfied' but rather a list of goals 'that must be executed'"* —
> `NetworkInboundCapacityGoal` is hard-coded as mandatory in upstream Cruise Control,
> regardless of what you configure as `hard.goals` on the cluster. The correct way to
> actually "turn off" a capacity goal is to **exclude it from `default.goals`** on the
> cluster, not try to downgrade it to soft (you can't, the classification is fixed in
> code). That's exactly the mechanism `skipHardGoalCheck` in section 13 uses to work around
> it. We reproduced this exact gotcha in practice in this lab — see section 12.
> ([original discussion](https://github.com/orgs/strimzi/discussions/9546))

## 12. Capacity Planning: `brokerCapacity` and the "1 Core" and Network Bugs

`Kafka.spec.cruiseControl.brokerCapacity` tells Cruise Control how much CPU/network each
broker has available — `CpuCapacityGoal`, `NetworkInboundCapacityGoal`, and
`NetworkOutboundCapacityGoal` compute violations against this number. Note there's **no
disk field** here: Strimzi derives disk capacity automatically from the volume sizes
configured on the `KafkaNodePool` — unlike plain Cruise Control, which requires a
manually maintained `capacityJBOD.json`.

```yaml
brokerCapacity:
  cpu: "2"                    # cores or millicores: "1", "1.500", "1500m"
  inboundNetwork: 200000KiB/s
  outboundNetwork: 200000KiB/s
  overrides:
    - brokers: [0]              # per-broker override — useful with heterogeneous hardware
      cpu: "4"
      inboundNetwork: 400000KiB/s
      outboundNetwork: 400000KiB/s
```

> **The production bug that confuses newcomers to Cruise Control the most:** if you
> **don't** configure `brokerCapacity.cpu`, Cruise Control assumes **1 core per broker** —
> no matter how many cores the node actually has. A real case reported in the Strimzi
> community showed a 6-broker cluster, each effectively using well more than 1 core, with
> Cruise Control reporting `CORE_NUM: 1` for all of them: 6 brokers × 1 core = 6 cores of
> "theoretical" capacity against ~859% combined utilization — `CpuCapacityGoal` concluded,
> completely wrongly, that it needed to **add at least 3 brokers**. The problem wasn't
> lack of real capacity; it was Cruise Control seeing 1/8th (or less) of the CPU the
> broker actually had. **Always configure `brokerCapacity.cpu` when your brokers have more
> than 1 core** — which, in practice, is always.
> ([original issue](https://github.com/strimzi/strimzi-kafka-operator/issues/5951))

> **The same category of bug exists for network, and it's easy to miss because nobody
> writes about it with the same fanfare as "1 core":** the default
> `inboundNetwork`/`outboundNetwork` is **10000KiB/s (~10MB/s) per broker** — a number
> that was already low for real hardware in 2015, and is trivially exceeded by any test
> producer burst, even on a local kind cluster running on Docker's loopback. We reproduced
> this deterministically testing this Day from scratch: with the 10MB/s default, the load
> from section 7 **permanently sinks** the `full-rebalance` proposal from section 8 with
> `OptimizationFailureException: [NetworkInboundCapacityGoal] Insufficient capacity for
> networkInbound` — and since `NetworkInboundCapacityGoal` is in the `spec.goals` list of
> `kafkarebalance-full.yaml` (and is hard-coded as mandatory anyway, per the same gotcha in
> section 11), the proposal fails until the "dirty" window ages out of the model — which
> can take over an hour depending on `num.broker.metrics.windows`. Setting
> `brokerCapacity.inboundNetwork`/`outboundNetwork` to a realistic value (like the
> 200000KiB/s in this `kafka-cluster.yaml`) avoids the problem entirely. Treat this as part
> of the same capacity planning you already do for CPU — it's not extra overhead, it's the
> same care, on a different field.

## 13. Incident-Scoped Custom Goals

Every `KafkaRebalance` can have its own `spec.goals`, different from the cluster's
`default.goals` — useful when you want to fix **one specific problem**, fast, without
paying the cost (in time and I/O) of re-optimizing the entire cluster against every default
goal.

[`kafkarebalance-disk-incident.yaml`](kafkarebalance-disk-incident.yaml) simulates exactly
that — a nearly full disk on one broker, right now, in production:

```yaml
spec:
  mode: full
  goals:
    - DiskCapacityGoal
    - DiskUsageDistributionGoal
  skipHardGoalCheck: true
  excludedTopics: "payments\\..*"
```

Three deliberate decisions here, each with an explicit trade-off:

- **Only two goals, both about disk.** We're not asking Cruise Control to also rebalance
  network, CPU, or replica count — we want to fix disk, and only disk, as fast as
  possible.
- **`skipHardGoalCheck: true`.** Recall section 11: the cluster's `hard.goals` must appear
  in the goal list of **every** proposal, unless you explicitly skip that check. Without
  this field, this proposal would fail for not including `NetworkInboundCapacityGoal` and
  the cluster's other hard goals. We're consciously accepting **not** to verify
  rack/network/CPU for this specific run — the goal is to put out the fire, not do full
  maintenance. The correct follow-up is applying a complete `kafkarebalance-full.yaml`
  (section 8) after the incident passes, to reconcile everything that was left out.
- **`excludedTopics: "payments\\..*"`.** An emergency rebalance is exactly the kind of
  operation you **don't** want accidentally touching the financial topic — the regex
  (`java.util.regex.Pattern` format) guarantees no `payments.processed` replica moves here,
  no matter what the Analyzer computes.

```bash
kubectl apply -f kafkarebalance-disk-incident.yaml -n kafka
kubectl describe kafkarebalance disk-incident-rebalance -n kafka
# review the Optimization Result — confirm no payments.* replica shows up as moved
kubectl annotate kafkarebalance disk-incident-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

## 14. Intra-Broker (JBOD) Rebalancing

So far, every rebalance moved replicas **between brokers**. But this Day's
[`kafka-nodepool-broker.yaml`](kafka-nodepool-broker.yaml) has **two JBOD volumes per
broker** (`id: 0` and `id: 1`) — and nothing guarantees the data ends up evenly distributed
between those two disks *within* the same broker. Cruise Control solves this with two
distinct mechanisms:

### `rebalanceDisk: true` — continuous balancing between disks

```yaml
# kafkarebalance-intra-broker.yaml
spec:
  mode: full
  rebalanceDisk: true
```

Turns on the `IntraBrokerDiskCapacityGoal`/`IntraBrokerDiskUsageDistributionGoal` goals —
moves replicas between disks of the **same** broker to equalize disk usage, analogous to
what `DiskUsageDistributionGoal` does between brokers, but one level down.

```bash
kubectl apply -f kafkarebalance-intra-broker.yaml -n kafka
kubectl annotate kafkarebalance intra-broker-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

> **If you hit a "cluster does not have JBOD storage config" error with JBOD configured:**
> this used to be a real bug in earlier Strimzi versions
> (`strimzi-kafka-operator#10280`) — validation didn't correctly recognize a `KafkaNodePool`
> with properly configured JBOD storage. It's since been fixed, but if you're on an older
> operator version, it's the first thing to check.

### `mode: remove-disks` — emptying a disk before physically removing it

A different scenario: you want to **remove a volume** (shrink from 2 disks to 1, for
example, or swap one disk for another). Before taking the volume out of the
`KafkaNodePool`, it needs to be empty:

```yaml
# kafkarebalance-remove-disks.yaml
spec:
  mode: remove-disks
  moveReplicasOffVolumes:
    - brokerId: 0
      volumeIds: [1]
```

```bash
kubectl apply -f kafkarebalance-remove-disks.yaml -n kafka
kubectl annotate kafkarebalance remove-disk-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance remove-disk-rebalance -n kafka -w
```

> **Bug reproduced in this lab: `brokerId` must be a real broker.** We first tested with
> `brokerId: 3` (assuming sequential numbering across both node pools) and the proposal
> failed with `IllegalArgumentException: Some/all brokers specified don't exist` —
> because in this lab the `controller` node pool gets IDs `[3,4,5]` and `broker` gets
> `[0,1,2]`; `3` is a controller, not a broker. Always check `kubectl get kafkanodepool
> broker -n kafka -o jsonpath='{.status.nodeIds}'` before assuming which ID to use.

Cruise Control moves the replicas from volume `1` on broker `0`, starting with the
**largest** and working down to the smallest, onto the remaining disks (both within the
same broker and on others). Two documented caveats worth knowing before running this in
production:

- **The proposal doesn't show the "before"** — only the expected final result, unlike
  `full`/`add-brokers`/`remove-brokers`, which bring an `Optimization Result` with a
  comparison.
- **The PVC isn't deleted automatically.** Once the volume is logically empty, the PVC
  still exists until you remove it manually — if you forget, Kafka might later assign new
  partitions to it, contradicting the intent of "I emptied this disk to remove it."

## 15. Performance Tuning: Concurrency and Throttling

Cruise Control's `Executor` doesn't move every replica in the proposal at once — it
respects concurrency and throttling limits, configurable per `KafkaRebalance`:

| Field | Default | What it controls |
|---|---|---|
| `concurrentPartitionMovementsPerBroker` | 5 | Simultaneous replica movements in/out of each broker |
| `concurrentIntraBrokerPartitionMovements` | 2 | Simultaneous movements between disks of the same broker (section 14) |
| `concurrentLeaderMovements` | 1000 | Simultaneous leadership swaps (much cheaper than moving a replica) |
| `replicationThrottle` | unlimited | Max bytes/second used by replica movement |
| `replicaMovementStrategies` | `BaseReplicaMovementStrategy` | Execution order of the movements |

[`kafkarebalance-throttled.yaml`](kafkarebalance-throttled.yaml) sets explicit, conservative
values — 10MiB/s of throttle and reduced concurrency:

```yaml
spec:
  concurrentPartitionMovementsPerBroker: 3
  concurrentLeaderMovements: 200
  replicationThrottle: 10485760
```

> **Bug reproduced in this lab: `replicaMovementStrategies` sinks any rebalance.** We
> originally tested with `replicaMovementStrategies` set (correct class names, copied
> straight from Cruise Control) to order execution — prioritizing under-replicated
> partitions and larger replicas first. Every attempt, approved or not, failed with
> `CruiseControlRestException: Unexpected status code 400`. The Cruise Control pod's log
> showed the real cause (the `KafkaRebalance` `status` only shows the generic 400 — another
> case for section 19): `WARN AbstractRequest:33 - Failed to parse parameters: {...} for
> request: /rebalance`. We isolated it by removing fields one at a time until only
> `replicaMovementStrategies` was left — with it out, everything else (concurrency,
> throttle) works normally. For safety, this manifest doesn't declare
> `replicaMovementStrategies`; if you want to control execution order, test it in
> isolation before trusting it during a real incident.

> **A real incident that motivates this manifest existing:** someone in the Strimzi
> community reported a rebalance of just 82MB (1000 replicas) taking **over an hour**, when
> a previous 80GB rebalance had taken 15 minutes. The cause, found after investigation:
> `concurrentLeaderMovements`, `concurrentPartitionMovementsPerBroker`, and
> `replicationThrottle` were all set to **0**, believing "0 = unlimited." It's the
> opposite — 0 means practically **no concurrent movement allowed**. The maintainer's
> recommendation was direct: if you're not sure which value to use, **omit these fields**
> and let Cruise Control use the defaults, which are already generous enough for most
> cases.
> ([original discussion](https://github.com/orgs/strimzi/discussions/7167))

```bash
kubectl apply -f kafkarebalance-throttled.yaml -n kafka
kubectl annotate kafkarebalance throttled-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

## 16. Full Self-Healing: the 5 Anomaly Types

Cruise Control's Anomaly Detector recognizes **five** types of anomaly:

| Anomaly | Config | Trigger | Self-healing action |
|---|---|---|---|
| **Broker failure** | `self.healing.broker.failure.enabled` | A registered broker disappears and doesn't come back within the grace window | Moves offline/under-replicated replicas to healthy brokers |
| **Disk failure** | `self.healing.disk.failure.enabled` | A disk (JBOD volume) dies with partitions going offline | Moves that disk's replicas to healthy disks — the automatic equivalent of section 14 |
| **Goal violation** | `self.healing.goal.violation.enabled` | A goal listed in `anomaly.detection.goals` stops being satisfied | Proactively computes and executes a fix proposal |
| **Metric anomaly** | `self.healing.metric.anomaly.enabled` | A collected metric goes out of pattern abruptly (e.g., a partition's bytes-in suddenly spikes) | Investigates/fixes the cause of the metric anomaly |
| **Topic anomaly** | `self.healing.topic.anomaly.enabled` | Topic configuration violates a policy (e.g., RF below the acceptable minimum) | Fixes the offending topic's configuration |

This lab enables the first three (`kafka-cluster.yaml`) and leaves `metric.anomaly` and
`topic.anomaly` off — every automatic self-healing type you turn on is a decision of "I
trust this detection enough to let Cruise Control act on its own," and it's worth turning
them on one at a time, understanding each one's behavior in isolation before stacking all
five.

### Broker failure in practice (and its caveat)

`self.healing.broker.failure.enabled: "true"` turns on the **Broker Failure Detector**:
Cruise Control watches which brokers are registered in the cluster and, if a broker that
previously existed disappears, it computes — and with self-healing on, **automatically
executes** — a proposal to fix any replica left offline/under-replicated because of that
loss. Three configs (not exposed in this lab's `cruiseControl.config`, but good to know
they exist) control this detector's sensitivity: `broker.failure.detection.backoff.ms`
(interval between checks), `broker.failure.alert.threshold.ms` (how long a broker is
missing before it becomes an alert), and `broker.failure.self.healing.threshold.ms` (how
long until self-healing actually fires) — the default behavior is already conservative
enough not to react to a few seconds of network blip.

> **A caveat worth its weight in gold for a technical video, confirmed by testing it
> live:** in this lab, brokers use `persistent-claim` (PVC) storage. If you run `kubectl
> delete pod my-cluster-broker-0 -n kafka` to "simulate a failure," the StrimziPodSet
> recreates the pod with the **same `nodeId`** and **reattaches the same PVC** — from the
> Kafka cluster's point of view, this is just a restart (the broker leaves and comes back
> with the same data), not a real broker failure:
> ```bash
> kubectl get pod my-cluster-broker-0 -n kafka -o jsonpath='{.spec.nodeName}'
> kubectl delete pod my-cluster-broker-0 -n kafka
> kubectl wait pod my-cluster-broker-0 -n kafka --for=condition=Ready --timeout=120s
> # confirm: same nodeId, same PVC (data-0-my-cluster-broker-0) — no self-healing triggered
> ```
> Cruise Control's real self-healing kicks in when a broker **disappears for good** from
> the cluster — lost `ephemeral` storage, a Kubernetes node replaced/removed, or the
> `KafkaNodePool` itself shrunk without going through `remove-brokers` from section 10.
> Testing this faithfully requires taking down the physical node/VM underneath the pod, not
> just the pod — out of scope for this local kind lab, but essential to understand before
> enabling automatic self-healing in production: you want to be sure it only fires for
> **real** losses, not every rolling-update restart.

> **Goal-violation self-healing deserves extra attention.** Unlike broker/disk failure
> (discrete events, clearly "something broke"), a goal violation can be triggered by
> something as ordinary as a temporary traffic spike on `clickstream.raw` — and
> self-healing, if enabled, will react with a real rebalancing proposal, actually moving
> data, with no human involved. `anomaly.detection.goals` (which must be a subset of
> `self.healing.goals`) defines which goals count toward this trigger — it's worth
> restricting this list to the goals you actually want to trigger automatic action, not
> using the entire `default.goals`.

With self-healing disabled for a given type, Cruise Control still **detects and notifies**
the anomaly (via the Anomaly Notifier — configurable webhook/email) without acting — a way
to get visibility without giving full autonomy to the automation, useful while you don't
yet trust that anomaly type enough to turn its self-healing on.

## 17. Full Automation: `autoRebalance`

Everything we did in sections 9/10 — scaling the node pool, then manually applying and
approving a `KafkaRebalance` — can be **fully automated** with
`spec.cruiseControl.autoRebalance`:

```yaml
autoRebalance:
  - mode: add-brokers
    template:
      name: auto-add-brokers-template
  - mode: remove-brokers
    template:
      name: auto-remove-brokers-template
```

The referenced `template`s are normal `KafkaRebalance` objects, but marked with the
`strimzi.io/rebalance-template: "true"` annotation
([`kafkarebalance-autoscale-templates.yaml`](kafkarebalance-autoscale-templates.yaml)) —
that turns them into **base configuration**, not real rebalance requests. Don't declare
`mode` or `brokers` on them: the Cluster Operator fills both in automatically the moment it
detects a scaling event, using the template only for the rest of the spec (goals, throttle,
etc.).

`autoRebalance` hasn't been enabled in `kafka-cluster.yaml` up to this point (see the
caveat in section 6) — enable it now, applying the templates and adding the block to the
`Kafka` CR:

```bash
kubectl apply -f kafkarebalance-autoscale-templates.yaml -n kafka

kubectl patch kafka my-cluster -n kafka --type=merge -p '
{
  "spec": {
    "cruiseControl": {
      "autoRebalance": [
        {"mode": "add-brokers", "template": {"name": "auto-add-brokers-template"}},
        {"mode": "remove-brokers", "template": {"name": "auto-remove-brokers-template"}}
      ]
    }
  }
}'

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=180s -n kafka
```

Test this by scaling the pool without applying any `KafkaRebalance` manually:

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka

# watch a KafkaRebalance appear on its own, without you applying anything:
kubectl get kafkarebalance -n kafka -w

# the Kafka CR also reflects the auto-rebalance state:
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.autoRebalance}'; echo
```

Unlike the manual flow, **`autoRebalance` doesn't wait for your approval** — the
automatically generated object is already born approved and executes on its own as soon as
the proposal is ready. It's real automation: you decide the policy once (the template), and
the operator applies it every time the cluster scales.

> **Production caveat (a recent, still-relevant issue):** there's a documented case where
> `autoRebalance` **silently fails to trigger** — if Cruise Control is in the middle of a
> rolling restart at the exact moment of the scaling event, an old instance might receive
> the rebalance request without yet having capacity information for the new broker, return
> an error, and the `KafkaAutoRebalancingReconciler` ends up **discarding** the generated
> `KafkaRebalance` without ever completing the rebalance — without alerting you. The
> documented workaround is simple: if you suspect this happened (the cluster scaled, but
> the new broker is still empty after a few minutes), apply a manual `add-brokers`
> `KafkaRebalance` (section 9 of this Day) to force it. Don't blindly trust `autoRebalance`
> right after upgrading/restarting Cruise Control itself — visually confirm the rebalance
> actually happened.
> ([original issue](https://github.com/strimzi/strimzi-kafka-operator/issues/11296))

## 18. Cruise Control REST API Security

The Cruise Control REST API allows potentially destructive operations — decommissioning a
broker, bulk replica moves, pausing/resuming sampling. By default, Strimzi already deploys
Cruise Control with:

- **HTTP Basic Auth + TLS enabled.**
- Two automatic internal users: **`admin`** (used by the operator itself to orchestrate
  everything we've seen so far) and **`healthcheck`** (only for the readiness probe).

If you (or a third-party tool, or a custom dashboard) need to talk to the API directly —
without going through `KafkaRebalance` — Strimzi lets you declare additional users via
`cruiseControl.apiUsers`, with two possible roles:

| Role | Access |
|---|---|
| `VIEWER` | Lightweight endpoints: `kafka_cluster_state`, `user_tasks`, `review_board` |
| `USER` | All `GET` endpoints, except `bootstrap`/`train` |
| (implicit) `ADMIN` | All endpoints — reserved for Strimzi internally |

```yaml
# Illustrative — requires a Secret with the credentials referenced here
cruiseControl:
  apiUsers:
    type: hash
    valueFrom:
      secretKeyRef:
        name: cruise-control-api-users
        key: cruise-control-auth.txt
```

> **Why this matters:** a lot of "plain" (non-Strimzi) Cruise Control tutorials run with
> `webserver.security.enable: false` to simplify the demo — and that sometimes leaks into
> copy-pasted production configuration. On Strimzi, turning this off is an **explicit,
> deliberate** step (`webserver.security.enable`/`webserver.ssl.enable` in
> `cruiseControl.config`), not the default. Don't turn it off unless you have a concrete
> reason and a network already isolated enough to compensate.

## 19. Known Production Issues

A curated list of real issues worth knowing before running Cruise Control seriously in
production — each already mentioned in context in the sections above; here's the
consolidated list with a direct link:

| Issue | Where in this README | Issue/Discussion |
|---|---|---|
| `hard.goals` doesn't mean "must be satisfied," it means "must be executed" | Section 11 | [strimzi #9546](https://github.com/orgs/strimzi/discussions/9546) |
| CPU capacity assumes 1 core per broker without explicit `brokerCapacity.cpu` | Section 12 | [strimzi #5951](https://github.com/strimzi/strimzi-kafka-operator/issues/5951) |
| Default network capacity (10MB/s) sinks `NetworkInboundCapacityGoal` under real load, even in kind | Section 12 | Reproduced in this lab (no associated public issue) |
| `add-brokers` against a freshly created broker returns a `NullPointerException` in `BrokerCapacityInfo.capacity()` before the 1st sampling window | Section 9 | Reproduced in this lab (no associated public issue) |
| `KafkaTopic` gets stuck `Terminating` if deleted after (or together with) the `Kafka` CR — the Topic Operator dies before removing the finalizer | Section 22 | Reproduced in this lab (no associated public issue) |
| Concurrency/throttle set to 0 hangs the rebalance (it's not "unlimited") | Section 15 | [strimzi #7167](https://github.com/orgs/strimzi/discussions/7167) |
| `replicaMovementStrategies` on a `KafkaRebalance` sinks the request with `400 Bad Request` / `Failed to parse parameters` | Section 15 | Reproduced in this lab (no associated public issue) |
| `brokerCapacity.overrides`/`moveReplicasOffVolumes` with a `controller` (non-broker) ID fail silently or with `IllegalArgumentException` | Sections 12 and 14 | Reproduced in this lab (no associated public issue) |
| `rebalanceDisk`/JBOD incorrectly rejected on `KafkaNodePool` (fixed) | Section 14 | [strimzi #10280](https://github.com/strimzi/strimzi-kafka-operator/issues/10280) |
| `autoRebalance` may not fire during a Cruise Control rolling restart | Section 17 | [strimzi #11296](https://github.com/strimzi/strimzi-kafka-operator/issues/11296) |
| Generic error messages in `KafkaRebalance` `status` — the real cause is only in the pod's log | All rebalance sections | [strimzi #8444](https://github.com/strimzi/strimzi-kafka-operator/issues/8444) |
| KRaft: `controller`-only nodes use a static quorum — Cruise Control doesn't rebalance them | General | Strimzi documentation on static KRaft quorum |
| The Cruise Control client trusts the server's public key instead of the Cluster CA — can conflict with CA renewal happening in parallel with a rebalance | Watch-list (recent, open issue) | [strimzi #12442](https://github.com/strimzi/strimzi-kafka-operator/issues/12442) |
| Cruise Control's Metrics Reporter stops working behind a service mesh (Istio/Cilium) intercepting internal traffic — not a Strimzi bug, an unsupported combination | Watch-list, only relevant outside kind | [strimzi #11869](https://github.com/orgs/strimzi/discussions/11869), [strimzi #12200](https://github.com/orgs/strimzi/discussions/12200) |

## 20. Cruise Control's Architectural Limits

A deliberately skeptical section, because being a Kafka specialist isn't just praising the
tool — it's knowing where it stops. Cruise Control is excellent at what it sets out to do,
but it operates **within** an architectural constraint that no software optimization
solves: **partition data lives on the broker's local disk.** This implies:

- **"Conservation of state":** if a replica has accumulated a large log and the new
  location chosen is another broker, someone has to copy those entire bytes over the
  network. No optimizer "erases" the bytes — the Analyzer can decide *what* to move in
  seconds, but the Executor still has to physically copy terabytes if that's the case.
  That's why throttling (section 15) is always a trade-off, never a cure: low throttle
  protects production traffic but stretches the rebalance window; high throttle finishes
  fast but competes with real producers/consumers for the same network.
- **A hot partition isn't fixed by a broker rebalance.** If a single partition has
  disproportionate throughput (a hot key, a tenant too large for a shared partition),
  moving that partition to another broker just moves the problem —
  `LeaderReplicaDistributionGoal` distributes *how many* partitions each broker leads, it
  doesn't reduce the load of one individual imbalanced partition within its own traffic.
  That's topic/partitioning design, not cluster capacity planning.
- **A new broker starts empty.** `add-brokers` (section 9) only helps once replicas or
  leadership migrate onto it — CPU/network capacity arrives before balanced traffic does.
  Unlike scaling stateless compute (where a new pod already processes traffic
  immediately), a new broker is, for a while, an investment with no return until the
  rebalance finishes.

None of this is a reason not to use Cruise Control — quite the opposite: understanding
these constraints is what lets you predict how long a real rebalance will take, and why
"just add another broker" isn't an instant fix. More recent Kafka architectures that
decouple storage from the broker (tiered storage, or shared/object storage) attack exactly
this constraint — worth keeping on your radar if hot partitions and slow rebalances are a
recurring pain in your cluster, but that's a topic for another Day.

## 21. Complete Scenario: Full Disk at 3 AM

Putting it all together — an incident walkthrough the way it would actually happen:

1. **03:47 — disk alert.** A broker is at 88% disk usage (well above the
   `disk.capacity.threshold` of 80% — section 11). `DiskCapacityGoal`, if you requested a
   proposal right now, would already be violated.
   ```bash
   kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
     --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
     --bootstrap-server my-cluster-kafka-bootstrap:9092
   kubectl logs -n kafka deployment/my-cluster-cruise-control --tail=100
   ```
2. **Decision: disk emergency, not full maintenance.** Apply
   [`kafkarebalance-disk-incident.yaml`](kafkarebalance-disk-incident.yaml) (section 13) —
   disk goals only, `skipHardGoalCheck: true`, `payments.processed` protected via
   `excludedTopics`.
   ```bash
   kubectl apply -f kafkarebalance-disk-incident.yaml -n kafka
   kubectl describe kafkarebalance disk-incident-rebalance -n kafka
   ```
3. **Review before approving.** Confirm in the `Optimization Result` that the disk
   reduction is enough and that no `payments.*` replica was touched.
   ```bash
   kubectl annotate kafkarebalance disk-incident-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
   kubectl get kafkarebalance disk-incident-rebalance -n kafka -w
   ```
4. **Once the disk normalizes, reconcile for real.** The `skipHardGoalCheck` from step 2
   left network/CPU/rack out of the check — in the morning, with the cluster stable, run a
   complete `kafkarebalance-full.yaml` (section 8), with all hard goals, to make sure the
   emergency fix didn't leave any other goal broken.
   ```bash
   kubectl apply -f kafkarebalance-full.yaml -n kafka
   kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
   ```

That's the real pattern: **fast, scoped response** to the acute symptom, followed by
**full reconciliation** once the pressure is off — not a single rebalance trying to do
both at once.

## 22. Cleanup

```bash
kubectl -n kafka delete kafkatopic --all
kubectl -n kafka delete kafkarebalance --all
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # should disappear on their own thanks to deleteClaim: true
kind delete cluster --name strimzi-day7
```

> **Why delete `KafkaTopic` first:** the finalizer `strimzi.io/topic-operator` on each
> `KafkaTopic` is removed by the Topic Operator, which runs inside the `entity-operator`
> pod — and that pod dies as soon as the `Kafka` CR is deleted. We reproduced in this lab
> what happens if you delete everything at once with `kubectl delete $(kubectl get strimzi
> -o name)` without deleting `KafkaTopic` first: it's a real race, and if
> `Kafka`/`entity-operator` gets removed before the Topic Operator processes the topic
> deletions, the `KafkaTopic` objects get stuck forever in `Terminating` with the finalizer
> never removed. Deleting the topics (and the `KafkaRebalance` objects, which depend on
> `Kafka` existing) first avoids this. If you already hit this trap, unstick it by forcing
> the finalizer off:
> `kubectl patch kafkatopic <name> -n kafka --type=merge -p '{"metadata":{"finalizers":[]}}'`.

## 23. References

| Resource | URL |
|---|---|
| Strimzi — Cruise Control for cluster rebalancing | https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str |
| Strimzi — KafkaRebalance API Reference | https://strimzi.io/docs/operators/latest/configuring#type-KafkaRebalance-reference |
| Strimzi — Blog: Cruise Control (original introduction, 2020) | https://strimzi.io/blog/2020/06/15/cruise-control/ |
| Strimzi — Blog: Moving data between JBOD disks using Cruise Control | https://strimzi.io/blog/2025/02/13/moving-data-between-jbod-disks-using-cruise-control/ |
| Strimzi — Blog: Auto-rebalancing on cluster scaling | https://strimzi.io/blog/2024/11/25/autorebalancing-on-scaling/ |
| Strimzi — Proposal 078: Auto-rebalancing on cluster scaling | https://github.com/strimzi/proposals/blob/main/078-auto-rebalancing-cluster-scaling.md |
| Red Hat — Streams for Apache Kafka (KRaft): Cruise Control concepts | https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str |
| Axual — Apache Kafka Cruise Control (practical overview) | https://axual.com/blog/apache-kafka-cruise-control |
| Confluent — Kafka Summit London 2023: An Introduction to Kafka Cruise Control | https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/ |
| Cruise Control — repository (active fork, post-LinkedIn) | https://github.com/cruise-control-for-kafka/cruise-control |
| Cruise Control (LinkedIn) — Wiki: Configurations (goals, thresholds) | https://github.com/linkedin/cruise-control/wiki/Configurations |
| Cruise Control — REST APIs | https://github.com/linkedin/cruise-control/wiki/REST-APIs |
| `hard.goals` execution vs. satisfaction — discussion | https://github.com/orgs/strimzi/discussions/9546 |
| CPU capacity — 1-core default issue | https://github.com/strimzi/strimzi-kafka-operator/issues/5951 |
| Zeroed concurrency hangs rebalance — discussion | https://github.com/orgs/strimzi/discussions/7167 |
| `rebalanceDisk` rejected on `KafkaNodePool` (fixed) | https://github.com/strimzi/strimzi-kafka-operator/issues/10280 |
| `autoRebalance` doesn't fire during a rolling restart | https://github.com/strimzi/strimzi-kafka-operator/issues/11296 |
| Generic error messages in `KafkaRebalance` | https://github.com/strimzi/strimzi-kafka-operator/issues/8444 |
| Cruise Control client and Cluster CA (open issue) | https://github.com/strimzi/strimzi-kafka-operator/issues/12442 |
| Cruise Control Metrics Reporter + Istio (upgrade breaks connectivity) | https://github.com/orgs/strimzi/discussions/11869 |
| Cruise Control Metrics Reporter + Istio/Cilium on KRaft | https://github.com/orgs/strimzi/discussions/12200 |
| AutoMQ — Cruise Control's architectural limits (critical perspective) | https://www.automq.com/blog/kafka-rebalancing-issues-cruise-control-architecture |
| kind | https://kind.sigs.k8s.io/ |
| Release used in this lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Part of the **Espetinho de Kafka** series — Strimzi Day 7: Cruise Control Advanced.
> Previous Day: [Cruise Control — Introduction](../Day6-CruiseControl/).
