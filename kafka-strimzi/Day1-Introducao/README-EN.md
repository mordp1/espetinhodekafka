# Strimzi Operator — Kafka on Kubernetes

> **Video:** [Strimzi Operator - Kafka on Kubernetes](https://www.youtube.com/watch?v=Sw8seG0h3q8) (PT-BR)
> **Goal:** Understand what the Strimzi Operator is, why it exists, and spin up your first
> Kafka cluster on Kubernetes using **kind** on your local machine.

---

## Table of Contents

1. [What is Strimzi](#1-what-is-strimzi)
2. [Prerequisites](#2-prerequisites)
3. [Lab Structure](#3-lab-structure)
4. [Bringing Up the Kind Cluster](#4-bringing-up-the-kind-cluster)
5. [Installing the Strimzi Cluster Operator](#5-installing-the-strimzi-cluster-operator)
6. [Deploying Kafka](#6-deploying-kafka)
7. [Creating a Topic](#7-creating-a-topic)
8. [Testing Produce and Consume](#8-testing-produce-and-consume)
9. [Cleanup](#9-cleanup)
10. [References](#10-references)

---

## 1. What is Strimzi

**Strimzi** is an operator for running **Apache Kafka** on **Kubernetes**. It follows the
[Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/): you
describe the Kafka cluster you want (how many brokers, how many controllers, storage,
listeners, topics, users...) through declarative YAML manifests (**Custom Resources**), and
the Strimzi Cluster Operator takes care of creating, updating and keeping all of that
running inside the cluster.

**Without Strimzi**, running Kafka on Kubernetes means manually managing StatefulSets,
Services, ConfigMaps, Secrets, rolling config updates, TLS certificates, and so on.
**With Strimzi**, that becomes a handful of Custom Resources:

| Custom Resource | What it's for |
|---|---|
| `Kafka` | Defines the Kafka cluster (version, listeners, configs) |
| `KafkaNodePool` | Defines a group of cluster nodes (brokers and/or controllers) — we'll dig deeper into this on Day 2 |
| `KafkaTopic` | Creates/manages topics via the Topic Operator |
| `KafkaUser` | Creates users and credentials via the User Operator |

In this Day 1, we use the simplest possible setup: **a single node** acting as both broker
and controller (`roles: [controller, broker]` — called **dual-role**), with `ephemeral`
storage (nothing persisted to disk — perfect for learning without worrying about storage
yet). In **Day 2**, we'll split broker and controller into separate **Kafka Node Pools** and
use persistent storage — the recommended setup for production.

> **Note:** Strimzi no longer uses Zookeeper — since version 0.46, every cluster runs in
> **KRaft** (Kafka Raft metadata mode) by default. You won't find any "zookeeper"
> `KafkaNodePool` in the manifests below — that doesn't exist anymore.

## 2. Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (`kind version` to check)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- ~4GB of free RAM for Docker

## 3. Lab Structure

```
Day1-Introducao/
├── kind-config.yaml          # single-node kind cluster
├── kafka-single-node.yaml    # dual-role KafkaNodePool + Kafka CR
├── kafka-topic-example.yaml  # test KafkaTopic
├── README.md
└── README-EN.md
```

## 4. Bringing Up the Kind Cluster

```bash
kind create cluster --config kind-config.yaml --name strimzi-day1
```

This creates a local 1-node Kubernetes cluster (control-plane) running inside a Docker
container, already with a default `StorageClass` (`standard`, via
[local-path-provisioner](https://github.com/rancher/local-path-provisioner)).

Confirm `kubectl` points to the new cluster's context:

```bash
kubectl cluster-info --context kind-strimzi-day1
```

## 5. Installing the Strimzi Cluster Operator

Create the namespace where everything will live:

```bash
kubectl create namespace kafka
```

Install the Cluster Operator from the official manifest of a **pinned** version (so the lab
doesn't break if Strimzi releases a new version after this video). The manifest uses
`myproject` as a namespace placeholder — we swap it for `kafka` with `sed` before applying:

```bash
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka
```

Watch the operator come up:

```bash
kubectl get pod -n kafka --watch
```

Wait for `Running` (Ctrl+C to exit the watch), or use:

```bash
kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploying Kafka

The [`kafka-single-node.yaml`](kafka-single-node.yaml) file has two resources: the
`KafkaNodePool` (1 replica, `roles: [controller, broker]`, `ephemeral` storage) and the
`Kafka` resource (version 4.3.0, internal `plain` + `tls` listeners, replication factor 1 —
consistent with a single node).

```bash
kubectl apply -f kafka-single-node.yaml -n kafka
```

Wait for the cluster to become ready (can take 1 to 3 minutes):

```bash
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

Check the pods and node pools:

```bash
kubectl get pods -n kafka
kubectl get kafkanodepool -n kafka
```

Expected output (trimmed):

```
NAME                          READY   STATUS    RESTARTS   AGE
my-cluster-dual-role-0        1/1     Running   0          90s
my-cluster-entity-operator-…  2/2     Running   0          40s
strimzi-cluster-operator-…    1/1     Running   0          3m

NAME        DESIRED REPLICAS   ROLES                     NODEIDS
dual-role   1                  ["controller","broker"]   [0]
```

Notice the `ROLES` column: the same node (`nodeId 0`) is both `controller` and `broker` —
that's what "dual-role" means. This is **KRaft** running with no Zookeeper.

## 7. Creating a Topic

```bash
kubectl apply -f kafka-topic-example.yaml -n kafka
kubectl get kafkatopic -n kafka
```

## 8. Testing Produce and Consume

**Produce messages** (Ctrl+D or Ctrl+C to stop the producer after typing):

```bash
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
```

**Consume messages** (in another terminal):

```bash
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning
```

Messages typed in the producer should show up in the consumer.

## 9. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl -n kafka delete -f kafka-topic-example.yaml
kind delete cluster --name strimzi-day1
```

## 10. References

| Resource | URL |
|---|---|
| Strimzi Quickstarts | https://strimzi.io/quickstarts/ |
| Strimzi Deploying Guide | https://strimzi.io/docs/operators/latest/deploying |
| Strimzi — Overview | https://strimzi.io/docs/operators/latest/overview |
| kind | https://kind.sigs.k8s.io/ |
| Strimzi examples repository | https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples |

---

> Part of the **Espetinho de Kafka** series — Strimzi Day 1: Introduction to the Operator.
> In **Day 2**, we split broker and controller into separate **Kafka Node Pools**, use
> persistent storage and a multi-node kind cluster — the recommended production setup.
