# Kafka Node Pools on Strimzi — KRaft in Practice

> **Goal:** Understand how **Kafka Node Pools** work on Strimzi, splitting `broker` and
> `controller` into separate groups, with persistent storage and a multi-node **kind**
> cluster — the recommended setup for production.

---

## Table of Contents

1. [Context](#1-context)
2. [What are Kafka Node Pools](#2-what-are-kafka-node-pools)
3. [Prerequisites](#3-prerequisites)
4. [Lab Structure](#4-lab-structure)
5. [Bringing Up the Kind Cluster (multi-node)](#5-bringing-up-the-kind-cluster-multi-node)
6. [Installing the Strimzi Cluster Operator](#6-installing-the-strimzi-cluster-operator)
7. [Deploying the Node Pools and Kafka](#7-deploying-the-node-pools-and-kafka)
8. [Validating the Cluster](#8-validating-the-cluster)
9. [Creating a Topic and Testing Produce/Consume](#9-creating-a-topic-and-testing-produceconsume)
10. [Scaling a Node Pool Live](#10-scaling-a-node-pool-live)
11. [Other Configs Worth Exploring](#11-other-configs-worth-exploring)
12. [Cleanup](#12-cleanup)
13. [References](#13-references)

---

## 1. Context

In [Day 1](../Day1-Introducao/) we spun up the simplest possible Strimzi setup: **1 node**
acting as both `controller` and `broker` (dual-role), with `ephemeral` storage. Great for
learning the Operator, terrible for production — a single node is a single point of failure,
and without persistent storage any restart loses your data.

In this Day 2 we take the next step: **separate Kafka Node Pools** — one pool just for
`controller`, another just for `broker` — each with its own replica count, storage and
configuration, running on a kind cluster with **multiple nodes** (1 control-plane + 2
workers), so you can actually see Kafka pods spread across different machines.

## 2. What are Kafka Node Pools

A **`KafkaNodePool`** is a Custom Resource representing a group of nodes inside a Kafka
cluster, each with a well-defined **role**:

| Role | Function |
|---|---|
| `broker` | Data plane — receives, stores and serves topic messages |
| `controller` | Control plane — manages cluster metadata via **Raft** (KRaft) |
| `broker` + `controller` (dual-role) | A single node handles both jobs (used in Day 1) |

Each `KafkaNodePool` has its own `replicas`, `roles` and `storage` — which lets you, for
example, give brokers bigger/faster disks than controllers, scale brokers and controllers
independently, or even mix different storage classes within the same cluster.

> **Historical note:** in older Strimzi versions, both **KRaft** and **Kafka Node Pools**
> were experimental, hidden behind *feature gates* (`+KRaft`, `+UseKRaft`,
> `+KafkaNodePools`) you had to enable manually on the Cluster Operator. Today, in the
> version used in this lab (**Strimzi 1.1.0**), both are **GA (General Availability) and
> on by default** — Zookeeper was removed from Strimzi starting with version 0.46. You
> can't (and don't need to) create a Zookeeper-based Kafka cluster on a current Strimzi
> anymore.

Splitting `broker` and `controller` into separate pools (instead of dual-role) makes the
concept more visible: in `kubectl get pods` you can clearly see which pods are control
plane and which are data plane, and you can scale each independently — as we do in
[section 10](#10-scaling-a-node-pool-live).

## 3. Prerequisites

- [Docker](https://docs.docker.com/get-docker/) with at least ~4GB of free RAM
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Having done [Day 1](../Day1-Introducao/) (recommended, not required)

## 4. Lab Structure

```
Day2-NodePools/
├── kind-config.yaml                # kind cluster: 1 control-plane + 2 workers
├── kafka-nodepool-controller.yaml  # "controller" KafkaNodePool (3 replicas)
├── kafka-nodepool-broker.yaml      # "broker" KafkaNodePool (3 replicas)
├── kafka-cluster.yaml              # Kafka CR (RF=3, min.insync.replicas=2)
├── kafka-topic-example.yaml        # test KafkaTopic (3 partitions, RF 3)
├── README.md
└── README-EN.md
```

## 5. Bringing Up the Kind Cluster (multi-node)

```bash
kind create cluster --config kind-config.yaml --name strimzi-day2
```

```yaml
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

Confirm the 3 nodes:

```bash
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

## 7. Deploying the Node Pools and Kafka

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

Each `KafkaNodePool` uses `persistent-claim` storage (JBOD, 5Gi, `deleteClaim: true` — so
cleanup automatically removes the PVCs once the cluster is deleted):

```yaml
# kafka-nodepool-broker.yaml (same shape as controller.yaml)
spec:
  replicas: 3
  roles:
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 5Gi
        deleteClaim: true
        kraftMetadata: shared
```

## 8. Validating the Cluster

```bash
kubectl get kafkanodepool -n kafka
kubectl get pods -n kafka -o wide
kubectl get pvc -n kafka
```

Real output from this lab (captured live):

```
NAME         DESIRED REPLICAS   ROLES            NODEIDS
broker       3                  ["broker"]       [0,1,2]
controller   3                  ["controller"]   [3,4,5]
```

```
NAME                          READY   STATUS    NODE
my-cluster-broker-0           1/1     Running   strimzi-day2-worker2
my-cluster-broker-1           1/1     Running   strimzi-day2-worker
my-cluster-broker-2           1/1     Running   strimzi-day2-worker2
my-cluster-controller-3       1/1     Running   strimzi-day2-worker
my-cluster-controller-4       1/1     Running   strimzi-day2-worker2
my-cluster-controller-5       1/1     Running   strimzi-day2-worker
```

Notice two things:

- The `NODEIDS` of the `broker` pool (`0,1,2`) and the `controller` pool (`3,4,5`) **never
  overlap** — every node in the Kafka cluster (regardless of pool) has a unique ID.
- Pods show up spread across `strimzi-day2-worker` and `strimzi-day2-worker2` — Kubernetes
  distributed the 6 pods across the cluster's 2 workers.

## 9. Creating a Topic and Testing Produce/Consume

```bash
kubectl apply -f kafka-topic-example.yaml -n kafka
kubectl get kafkatopic -n kafka
```

**Produce:**

```bash
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
```

**Consume** (in another terminal):

```bash
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning
```

## 10. Scaling a Node Pool Live

One of the biggest advantages of Node Pools: scaling brokers and controllers
**independently**, without touching the rest of the cluster. `KafkaNodePool` supports the
`/scale` subresource, so you can use `kubectl scale` directly:

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka
```

Watch the new broker come up:

```bash
kubectl get kafkanodepool broker -n kafka
kubectl get pods -n kafka -o wide | grep broker
```

Real result from this lab — the new broker automatically got the next free `nodeId` (`6`,
since `3`, `4` and `5` belong to the `controller` pool):

```
NAME     DESIRED REPLICAS   ROLES        NODEIDS
broker   4                  ["broker"]   [0,1,2,6]
```

```
my-cluster-broker-6   1/1   Running   strimzi-day2-worker
```

The cluster stays `Ready` throughout — no downtime, no manual rebalancing, no editing the
`Kafka` CR. To scale back down:

```bash
kubectl scale kafkanodepool broker --replicas=3 -n kafka
```

## 11. Other Configs Worth Exploring

Left as a hook for you to explore (and for upcoming videos in the series):

- **Multi-volume JBOD** — a `KafkaNodePool` can have more than one volume under
  `storage.volumes` (separate disks for the data log and for the KRaft metadata, for
  example).
- **`resources` / `limits`** — CPU and memory per pool, letting you size brokers and
  controllers differently.
- **Rack awareness** (`rack.topologyKey`) — spreads replicas across availability zones.
- **Tiered Storage** — offloading old segments to object storage (S3, GCS...).
- **`KafkaUser` + authentication** (SCRAM/TLS) — this lab has no authentication enabled on
  purpose, to keep the scope tight; it's the natural topic for the next Day in the series.

## 12. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # should disappear on their own thanks to deleteClaim: true
kind delete cluster --name strimzi-day2
```

## 13. References

| Resource | URL |
|---|---|
| Strimzi Quickstarts | https://strimzi.io/quickstarts/ |
| Strimzi Deploying Guide (Node Pools, KRaft) | https://strimzi.io/docs/operators/latest/deploying |
| KIP-500 / KRaft | https://cwiki.apache.org/confluence/display/KAFKA/KIP-500 |
| kind | https://kind.sigs.k8s.io/ |
| Strimzi examples repository | https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/kafka |
| Release used in this lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Part of the **Espetinho de Kafka** series — Strimzi Day 2: Kafka Node Pools.
> Next Day: authentication and authorization (SCRAM/TLS + ACLs) with `KafkaUser`.
