# Kafka Node Pools on Strimzi — Advanced

> **Goal:** Go beyond the [Kafka Node Pools](../Day2-NodePools/) basics by exploring
> **node ID management**, **per-pool storage and scheduling**, and **KRaft controller
> quorum patterns** — based on the 5-part blog series the Strimzi team itself published
> back when the feature was still experimental.

---

## Table of Contents

1. [Context](#1-context)
2. [Prerequisites](#2-prerequisites)
3. [Lab Structure](#3-lab-structure)
4. [Bringing Up the Cluster (with Simulated Zones)](#4-bringing-up-the-cluster-with-simulated-zones)
5. [Installing the Strimzi Cluster Operator](#5-installing-the-strimzi-cluster-operator)
6. [Deploying: 3 Node Pools with Different Storage and Scheduling](#6-deploying-3-node-pools-with-different-storage-and-scheduling)
7. [Validating Per-Zone Scheduling and Per-Pool Storage](#7-validating-per-zone-scheduling-and-per-pool-storage)
8. [Topic and Produce/Consume](#8-topic-and-produceconsume)
9. [Node ID Management](#9-node-id-management)
10. [Controller Quorum Patterns in KRaft](#10-controller-quorum-patterns-in-kraft)
11. [From Feature Gate to GA — What Changed Since 2023](#11-from-feature-gate-to-ga--what-changed-since-2023)
12. [Cleanup](#12-cleanup)
13. [References](#13-references)

---

## 1. Context

In [Day 2](../Day2-NodePools/) we split `broker` and `controller` into separate Node Pools
and scaled one pool live. That covers the essentials, but Strimzi Node Pools go much
deeper — documented by the Strimzi team itself in a 5-part blog series, written back in
2023 when the feature was still **alpha**, hidden behind feature gates:

1. [Introduction](https://strimzi.io/blog/2023/08/14/kafka-node-pools-introduction/) — what it is and why it exists
2. [Node ID Management](https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/) — how IDs are assigned and reused
3. [Storage and Scheduling](https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/) — per-pool configuration
4. [Supporting KRaft](https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/) — controller quorum patterns
5. [What's Next](https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/) — the roadmap at the time (feature gate → beta → GA)

This Day 3 reproduces and validates, hands-on, the core points from those 5 posts —
including what happened once that 2023 roadmap became reality in the **Strimzi 1.1.0** we
use here (section 11).

## 2. Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with at least ~4GB of free RAM
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Having done [Day 2](../Day2-NodePools/) (recommended — we assume you already know the
  basic `KafkaNodePool` concept)

## 3. Lab Structure

```
Day3-NodePools-Avancado/
├── kind-config.yaml                  # kind cluster: 1 control-plane + 2 workers
├── kafka-nodepool-controller.yaml    # "controller" KafkaNodePool (3 replicas)
├── kafka-nodepool-broker-zone1.yaml  # "broker-zone1" KafkaNodePool (2 replicas, 5Gi, pinned to zone1)
├── kafka-nodepool-broker-zone2.yaml  # "broker-zone2" KafkaNodePool (2 replicas, 8Gi, pinned to zone2)
├── kafka-cluster.yaml                # Kafka CR (RF=3, min.insync.replicas=2)
├── kafka-topic-example.yaml          # test KafkaTopic (4 partitions, RF 3)
├── README.md
└── README-EN.md
```

## 4. Bringing Up the Cluster (with Simulated Zones)

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day3
```

To demonstrate per-zone scheduling without a real cloud provider, we label the two kind
workers as if they were different availability zones:

```bash
kubectl label node strimzi-day3-worker  topology.kubernetes.io/zone=zone1 --overwrite
kubectl label node strimzi-day3-worker2 topology.kubernetes.io/zone=zone2 --overwrite
```

## 5. Installing the Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploying: 3 Node Pools with Different Storage and Scheduling

The [Storage and Scheduling](https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/)
post shows that each `KafkaNodePool` can have its own storage (size/class) and its own
scheduling rule via `.spec.template.pod.affinity` — instead of one config for the whole
cluster. We reproduce that with 2 broker pools, each pinned to a zone and with a different
disk size:

```yaml
# kafka-nodepool-broker-zone1.yaml
spec:
  replicas: 2
  roles: [broker]
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 5Gi                 # zone1: smaller disk
        deleteClaim: true
        kraftMetadata: shared
  template:
    pod:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: topology.kubernetes.io/zone
                    operator: In
                    values: [zone1]
```

`kafka-nodepool-broker-zone2.yaml` is identical, swapping `zone1` → `zone2` and
`size: 5Gi` → `size: 8Gi` (simulating a different storage tier per zone).

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker-zone1.yaml -n kafka
kubectl apply -f kafka-nodepool-broker-zone2.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

## 7. Validating Per-Zone Scheduling and Per-Pool Storage

```bash
kubectl get kafkanodepool -n kafka
kubectl get pods -n kafka -o wide
kubectl get pvc -n kafka -o custom-columns=NAME:.metadata.name,SIZE:.status.capacity.storage,STATUS:.status.phase
```

Real output from this lab:

```
NAME           DESIRED REPLICAS   ROLES            NODEIDS
broker-zone1   2                  ["broker"]       [0,1]
broker-zone2   2                  ["broker"]       [2,3]
controller     3                  ["controller"]   [4,5,6]
```

```
NAME                         NODE
my-cluster-broker-zone1-0    strimzi-day3-worker    ← zone1 ✓
my-cluster-broker-zone1-1    strimzi-day3-worker    ← zone1 ✓
my-cluster-broker-zone2-2    strimzi-day3-worker2   ← zone2 ✓
my-cluster-broker-zone2-3    strimzi-day3-worker2   ← zone2 ✓
my-cluster-controller-4      strimzi-day3-worker2
my-cluster-controller-5      strimzi-day3-worker
my-cluster-controller-6      strimzi-day3-worker2
```

```
NAME                               SIZE   STATUS
data-0-my-cluster-broker-zone1-0   5Gi    Bound
data-0-my-cluster-broker-zone1-1   5Gi    Bound
data-0-my-cluster-broker-zone2-2   8Gi    Bound   ← different storage per pool ✓
data-0-my-cluster-broker-zone2-3   8Gi    Bound
```

Both `broker-zone1` brokers landed **only** on the node labeled `zone1`, and
`broker-zone2`'s **only** on `zone2` — per-pool `nodeAffinity` worked exactly as the post
describes. `controller` (with no affinity set) was left free for Kubernetes to spread
across both workers.

## 8. Topic and Produce/Consume

```bash
kubectl apply -f kafka-topic-example.yaml -n kafka
```

```bash
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic

kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning
```

## 9. Node ID Management

The [Node ID Management](https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/)
post explains that, by default, Strimzi assigns **sequential, global** IDs across all pools
in the cluster (notice above: `broker-zone1` got `[0,1]`, `broker-zone2` got `[2,3]`, and
`controller` got `[4,5,6]` — no ID repeats across pools).

### 9.1 Picking the next ID with `strimzi.io/next-node-ids`

To control which ID a new node gets when scaling up (instead of letting Strimzi pick the
next sequential one), annotate the pool before scaling:

```bash
kubectl annotate kafkanodepool broker-zone1 strimzi.io/next-node-ids="[100-109]" -n kafka
kubectl scale kafkanodepool broker-zone1 --replicas=3 -n kafka
```

Real result from this lab — the new node got the **lowest available ID within the given
range** (`100`), not the `2` that would be the next global sequential ID:

```
NAME           DESIRED REPLICAS   ROLES        NODEIDS
broker-zone1   3                  ["broker"]   [0,1,100]
```

### 9.2 Picking which node to remove with `strimzi.io/remove-node-ids`

By default, scaling down removes the **highest ID**. To pick a specific node instead:

```bash
kubectl annotate kafkanodepool broker-zone1 strimzi.io/remove-node-ids="[100]" -n kafka
kubectl scale kafkanodepool broker-zone1 --replicas=2 -n kafka
kubectl annotate kafkanodepool broker-zone1 strimzi.io/remove-node-ids- -n kafka  # remove the annotation afterward
```

> **Real finding from this lab (and why it's worth recording on video):** on the first
> attempt, we tried removing node `0` instead of `100`. Strimzi **refused**:
>
> ```
> WARN  KafkaClusterCreator: Cannot scale down brokers [0] because [0] have assigned partition-replicas
> WARN  KafkaClusterCreator: Reverting scale-down of KafkaNodePool broker-zone1 by changing number of replicas to 3
> ```
>
> Strimzi **never removes a broker that still has partition replicas assigned to it** — it
> reverts `replicas` on its own to protect your data. We confirmed with
> `kafka-topics.sh --describe` that node `100` had no replicas at all (it had just joined
> the cluster), removed that one instead of `0`, and it worked. This is a real operator
> safety net — in production, moving replicas off a broker before removing it (manually or
> via Cruise Control) is mandatory.

### 9.3 ID limit and `reserved.broker.max.id`

By default Kafka only accepts IDs from **0 to 999** (`reserved.broker.max.id`). If you want
to use higher ID ranges (e.g. `[10000-10099]`), you need to raise that limit in the `Kafka`
CR's `config` first.

## 10. Controller Quorum Patterns in KRaft

The [Supporting KRaft](https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/)
post describes 3 ways to arrange `broker` and `controller` across Node Pools — every KRaft
cluster needs **at least one pool with `controller`** and **at least one pool with
`broker`**:

| Pattern | Shape | When to use |
|---|---|---|
| **Combined (dual-role)** | 1 pool, `roles: [controller, broker]` | Labs, dev — what we did in [Day 1](../Day1-Introducao/) |
| **Dedicated** | 1 `controller`-only pool + 1+ `broker`-only pools | Production — what we did in [Day 2](../Day2-NodePools/) and here |
| **Hybrid** | A mix of dual-role and broker-only pools | Gradual migration between the two patterns above |

**Recommendation for controller count:** an **odd** number — `3` or `5` — because KRaft
uses **Raft** consensus, which needs a majority (`quorum`) to elect a metadata leader. With
an even number you waste a node without gaining extra fault tolerance (3 controllers
tolerate 1 failure; so does 4, just with one extra idle node).

## 11. From Feature Gate to GA — What Changed Since 2023

The last post in the series, [What's Next](https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/)
(September 2023), laid out a roadmap for the feature. Here's what was promised versus what
actually happened, compared against the Strimzi **1.1.0** we use in this lab:

| Promised in 2023 | Reality in Strimzi 1.1.0 (today) |
|---|---|
| `+KafkaNodePools` feature gate becomes **beta** and default in 0.39 | ✅ Happened — and went further |
| Feature gate becomes **GA** in 0.41 | ✅ Node Pools is GA, no feature gate at all |
| Zookeeper would stick around a while longer | ❌ **Fully removed** in 0.46 — only KRaft exists now |
| New `v1` API without Zookeeper/replicas/storage fields on `Kafka` | ✅ It's exactly the `kafka.strimzi.io/v1` API we use in every manifest in this lab |
| Clusters without `KafkaNodePool` would keep working via a "virtual pool" | No longer applicable — every cluster needs an explicit `KafkaNodePool` today |

In other words: what was an **alpha** feature in 2023, hidden behind a feature gate and
living alongside legacy Zookeeper, is today simply **the only way to run Kafka on
Strimzi**.

## 12. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # should disappear on their own thanks to deleteClaim: true
kind delete cluster --name strimzi-day3
```

## 13. References

| Resource | URL |
|---|---|
| Kafka Node Pools — Introduction | https://strimzi.io/blog/2023/08/14/kafka-node-pools-introduction/ |
| Kafka Node Pools — Node ID Management | https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/ |
| Kafka Node Pools — Storage and Scheduling | https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/ |
| Kafka Node Pools — Supporting KRaft | https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/ |
| Kafka Node Pools — What's Next | https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/ |
| Strimzi Deploying Guide | https://strimzi.io/docs/operators/latest/deploying |
| Release used in this lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Part of the **Espetinho de Kafka** series — Strimzi Day 3: Advanced Kafka Node Pools.
> Next Day: authentication and authorization (SCRAM/TLS + ACLs) with `KafkaUser`.
