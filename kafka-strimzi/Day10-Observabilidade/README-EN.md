# Kafka Observability on Kubernetes — Prometheus, Grafana, Kube State Metrics, Alerts, End-to-End Tracing and GitOps

> **Goal:** answer, on a real Strimzi cluster, the three questions that matter when something
> breaks at 3 a.m.: **(1) is the product working? (2) is Kafka healthy? (3) where did this
> specific message go, and where was it slow?** The lab builds **Prometheus + Alertmanager +
> Grafana + kube-state-metrics + Tempo (traces)** on top of a Strimzi cluster, with a sample
> pipeline (`producer → orders → processor → orders.processed → sink`) that generates traffic,
> business metrics and **one trace that crosses two topics and three services**. Everything —
> operators, dashboards, alert rules, notification routes, datasource — is **code in Git**,
> applied by **ArgoCD** and validated by a **CI with unit tests for alerts (`promtool`)**. Every
> scenario in this Day was run end to end on kind (Strimzi 1.1.0, Kafka 4.3.0, ArgoCD 3.4.6,
> kube-prometheus-stack 93.3.0 with Prometheus 3.16.0, Tempo 2.9.0) — the outputs shown are real.
> What was **not** run is listed, plainly, in section 12.
>
> **This README is also the runbook:** the `bash` blocks in sections 7 to 9 run in order, by
> copy and paste, and were validated from scratch on a clean kind cluster.

---

## Table of Contents

1. [Context: three questions, and why "end to end" is hard](#1-context-three-questions-and-why-end-to-end-is-hard)
2. [Architecture](#2-architecture)
3. [Where Strimzi metrics come from](#3-where-strimzi-metrics-come-from)
4. [The GitOps methodology](#4-the-gitops-methodology)
5. [Prerequisites](#5-prerequisites)
6. [Lab layout](#6-lab-layout)
7. [Bringing the lab up](#7-bringing-the-lab-up)
8. [Tour: Grafana, Prometheus, Alertmanager and ArgoCD](#8-tour-grafana-prometheus-alertmanager-and-argocd)
9. [Hands-on scenarios](#9-hands-on-scenarios)
10. [End-to-end tracing](#10-end-to-end-tracing)
11. [Going to production](#11-going-to-production)
12. [What this lab does NOT cover (honestly)](#12-what-this-lab-does-not-cover-honestly)
13. [Cleanup](#13-cleanup)
14. [Suggested video script](#14-suggested-video-script)
15. [References](#15-references)

---

## 1. Context: three questions, and why "end to end" is hard

Kafka is **asynchronous**: the producer does not know who consumes, the consumer does not know who
produced, and between them sits a log. That has an uncomfortable consequence for observability:

- **A green broker does not mean a working product.** A stuck consumer, a poison message or a slow
  downstream service leave every broker panel green and the customer without a notification.
- **A working product does not mean a healthy Kafka.** The pipeline can be fine *right now* with a
  broker down and `min.insync.replicas` at the limit — the next failure becomes an outage.
- **A normal trace breaks at the topic.** Each service emits its own spans, but without
  **propagating the context inside the message**, Tempo/Jaeger shows three loose traces instead
  of one story.

The dashboard and the alerts in this Day are organized by exactly those three questions:

| Question | Signal | Source |
|---|---|---|
| **1. Does the product work?** | throughput per stage, **end-to-end latency (p95)**, error rate, lag | app business metrics + Kafka Exporter |
| **2. Is Kafka healthy?** | under-replicated / under-min-ISR / offline partitions, active controller, pods Ready, CR status | Strimzi Metrics Reporter + kube-state-metrics |
| **3. Where did *this* message go?** | a single `producer → processor → sink` trace | OpenTelemetry → Tempo |

## 2. Architecture

```text
                         ┌────────────────────── namespace: demo ───────────────────────┐
                         │  order-producer ──► [orders] ──► order-processor ──► [orders.processed] ──► order-sink  │
                         │   :8000/metrics      (6 part.)     :8000/metrics        (6 part.)           :8000/metrics │
                         └──────┬────────────────────────────────────┬─────────────────────────────────────┬──────┘
                    OTLP/gRPC (traces, context in the Kafka header)   │ PodMonitor (business metrics)       │
                                │                                     │                                     │
  ┌──────── namespace: kafka ───┴─────────┐          ┌────────────── namespace: monitoring ───────────────────────────────┐
  │ my-cluster (3 controller+broker nodes)│          │                                                                     │
  │  :9404  Strimzi Metrics Reporter ─────┼─PodMon──►│  Prometheus ──rules──► Alertmanager ──AlertmanagerConfig──► webhook │
  │ Kafka Exporter (lag, offsets) ────────┼─PodMon──►│     ▲  ▲  ▲                                                         │
  │ Entity Operator (Topic+User) ─────────┼─PodMon──►│     │  │  └─ kube-state-metrics (native: pods, PVCs, Deployments)     │
  └───────────────────────────────────────┘          │     │  └──── strimzi-kube-state-metrics (STATUS of Strimzi CRs)       │
  ┌── namespace: strimzi-operator ──┐                │     │                                                              │
  │ Cluster Operator ───────────────┼───PodMonitor──►│     │            Grafana ◄── datasources: Prometheus + Tempo       │
  └─────────────────────────────────┘                │     │              ▲         dashboards (ConfigMaps in Git)        │
                                                     │   Tempo (traces) ──┘                                                │
                                                     └─────────────────────────────────────────────────────────────────────┘
  ┌── namespace: argocd ───────────────────────────────────────────────────────────────────────────────────────────────────┐
  │  observability-root ──► 6 Applications (strimzi-operator, kube-prometheus-stack, tempo, kafka, observability, demo-apps) │
  │                                                      ▲                                                                  │
  │                                          Git (repo "observability"): the ONLY source of truth                          │
  └──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

| Component | Version | Where it comes from |
|---|---|---|
| Strimzi Cluster Operator | 1.1.0 | official chart (`strimzi.io/charts`) |
| Kafka | 4.3.0 (KRaft, 3 dual-role nodes) | `Kafka` + `KafkaNodePool` CRs |
| kube-prometheus-stack | 93.3.0 (Prometheus 3.16.0, Prometheus Operator 0.95.2) | `prometheus-community` chart |
| Grafana | the one in the chart above | dashboards/datasources via sidecar (label) |
| Tempo | 2.9.0 (single-binary, `grafana/tempo` chart 1.24.4) | `grafana` chart |
| kube-state-metrics for CRs | v2.16.0 | official Strimzi manifests (`examples/metrics/kube-state-metrics`) |
| ArgoCD | 3.4.6 | official manifest |
| Sample app | Python 3.12, `confluent-kafka` 2.16.1, OpenTelemetry SDK 1.45.2 | `lab/app/` (local image on kind) |

Addresses (via kind `extraPortMappings` — no `port-forward` needed):

| Service | URL | Credentials |
|---|---|---|
| Grafana | <http://localhost:3000> | `admin` / `admin` (**lab only**) |
| Prometheus | <http://localhost:9090> | — |
| Alertmanager | <http://localhost:9093> | — |
| ArgoCD (optional) | <https://localhost:8080> via `port-forward` (section 7.3) | `admin` / `argocd-initial-admin-secret` |

## 3. Where Strimzi metrics come from

This is the table most worth showing on camera: "Kafka metrics" is not one thing, it is **six
different sources**, each answering a question the others cannot.

| Source | Answers | How Strimzi wires it | Example metric |
|---|---|---|---|
| **Strimzi Metrics Reporter** (inside broker/controller) | Kafka's internal health | `spec.kafka.metricsConfig.type: strimziMetricsReporter` → `/metrics` on port `9404` (`tcp-prometheus`) | `kafka_server_replicamanager_underreplicatedpartitions` |
| **Kafka Exporter** (separate pod) | **consumer-group lag**, offsets per topic/partition | `spec.kafkaExporter: {}` | `kafka_consumergroup_lag` |
| **Operators** (Cluster, Topic, User) | is the operator reconciling? how many failures? | already expose `/metrics`; only the `PodMonitor` is missing | reconciliation metrics |
| **Native kube-state-metrics** | state of Kubernetes objects: pod Ready? PVC? Deployment replicas? | ships with `kube-prometheus-stack` | `kube_pod_status_ready` |
| **kube-state-metrics for Strimzi CRs** | the **`status` of the CRs** (`KafkaTopic`, `KafkaUser`, `Kafka`, `KafkaNodePool`, `KafkaRebalance`, `KafkaConnect`...) as metrics | 2nd KSM instance with `--custom-resource-state-only` + a configuration `ConfigMap` | `strimzi_kafka_topic_resource_info{ready="False"}` |
| **App metrics** | the **product**: throughput, errors, end-to-end latency | a `PodMonitor` the team itself ships next to its `Deployment` | `demo_end_to_end_latency_seconds` |

**Metrics Reporter vs. JMX Prometheus Exporter.** Before the Metrics Reporter, metrics were exposed
with `jmxPrometheusExporter` — a Java agent that reads MBeans over JMX and translates them with
**regex rules in a `ConfigMap`** that you have to maintain. `strimziMetricsReporter` runs inside the
JVM as Kafka's own *metrics reporter* and needs no `ConfigMap`:

```yaml
# gitops/manifests/kafka/kafka.yaml
spec:
  kafka:
    metricsConfig:
      type: strimziMetricsReporter     # that's it. No ConfigMap with regex rules.
```

In the lab, the metric names that the official Strimzi rules and dashboards expect
(`kafka_server_replicamanager_*`, `kafka_controller_kafkacontroller_*`, `kafka_log_log_size`...)
**exist** with the Metrics Reporter — checked in Prometheus. The `Strimzi Kafka` and `Strimzi KRaft`
dashboards used here are the **Metrics Reporter variants**
(`examples/metrics/strimzi-metrics-reporter/grafana-dashboards/`), not the JMX Exporter ones.

> **Why the Kafka Exporter is not optional in practice:** the broker **does not know** what "lag"
> is. Lag is `log-end-offset − committed-offset`, and the exporter computes it by querying the
> broker. Without it, "my consumer is behind" becomes guesswork.

> **Why a KSM just for the CRs:** the status of a `KafkaTopic` (`Ready=False` because the Topic
> Operator could not create the topic) **is not a Kafka error** — Kafka is fine. It is an error in
> *your YAML*. Only the CR `status` knows, and ArgoCD will say "Synced". That is the gap scenario C
> (section 9) shows.

## 4. The GitOps methodology

### 4.1 App of apps with sync waves

A single manual `kubectl apply` (`bootstrap/root-app.yaml`). From there on, the cluster is whatever
Git says it is. `observability-root` watches the `apps/` folder and creates one `Application` per file:

| Wave | `Application` | What it installs | Source |
|---|---|---|---|
| 0 | `strimzi-operator` | Cluster Operator + CRDs | official chart 1.1.0 |
| 0 | `kube-prometheus-stack` | Prometheus Operator, Prometheus, Alertmanager, Grafana, KSM, CRDs | `prometheus-community` chart |
| 1 | `tempo` | trace backend | `grafana/tempo` chart |
| 1 | `kafka` | `Kafka`, `KafkaNodePool`, `KafkaTopic` | `manifests/kafka/` |
| 2 | `observability` | PodMonitors, PrometheusRules, AlertmanagerConfig, dashboards, datasource, KSM for CRs, lab webhook | `manifests/observability/` |
| 3 | `demo-apps` | producer, processor, sink + their `PodMonitor` | `manifests/demo-apps/` |

Waves solve "the CR arrived before the CRD". Since ArgoCD does not wait for a CRD to appear within a
single Application, each child has a `retry` with backoff and `SkipDryRunOnMissingResource=true` —
if the CRD does not exist yet, it simply tries again.

### 4.2 Everything is a CR discovered by label

No Prometheus, Alertmanager or Grafana configuration file is edited. Each piece is an object that the
respective operator/sidecar finds on its own:

| I want... | I create... | Who discovers it |
|---|---|---|
| Prometheus to scrape a pod | `PodMonitor` / `ServiceMonitor` | Prometheus Operator |
| an alert | `PrometheusRule` | Prometheus Operator |
| a notification route | `AlertmanagerConfig` | Prometheus Operator |
| a dashboard | `ConfigMap` with label `grafana_dashboard: "1"` (generated by `kustomize` from the `.json`) | Grafana sidecar |
| a datasource | `ConfigMap` with label `grafana_datasource: "1"` | Grafana sidecar |

**Observability is part of the app's delivery.** Notice that the pipeline's `PodMonitor` lives next to
its `Deployments` (`manifests/demo-apps/apps.yaml`), not in the platform repo. The team that ships the
service also ships "how to observe me" — no ticket required.

### 4.3 The flow of a change

```text
PR (alert, dashboard, threshold, app)
  └─► CI: ci/validate.sh ─ kustomize build ─ dashboard JSON ─ promtool check ─ promtool TEST (unit tests)
        └─► review: CODEOWNERS (whoever gets paged by the alert approves the alert)
              └─► merge ─► ArgoCD syncs ─► Prometheus Operator regenerates the config ─► Prometheus reloads
```

The repo's `.github/CODEOWNERS` expresses the rule "whoever is paged by the alert owns the alert":

```text
/manifests/observability/rules/                   @acme-corp/kafka-platform @acme-corp/sre
/manifests/observability/alertmanagerconfig.yaml  @acme-corp/sre
/manifests/demo-apps/                             @acme-corp/orders-team
```

### 4.4 The CI: alerts with unit tests

[`gitops/ci/validate.sh`](gitops/ci/validate.sh) runs locally and on GitHub Actions
([`validate.yaml`](gitops/.github/workflows/validate.yaml)): (1) `kustomize` renders, (2) dashboards
are valid JSON (broken JSON makes the sidecar **silently skip the ConfigMap**), (3) `promtool check
rules`, (4) **`promtool test rules`** — you *invent* the series and assert what must (or must not) fire.
See section 9, scenario E, with real failures.

### 4.5 Pitfalls the lab ran into (each one cost time)

1. **"My `PodMonitor` does nothing."** By the chart's defaults, `kube-prometheus-stack` only selects
   `PodMonitor`/`ServiceMonitor`/`PrometheusRule` carrying the label `release=<helm release>`. To
   discover *all* of them (including Strimzi's and the teams'), the three
   `*SelectorNilUsesHelmValues` are `false` (`apps/10-kube-prometheus-stack.yaml`).
   *(Documented chart behavior; the lab is born with the fix, so the failure was not reproduced.)*
2. **The alert fires, but nobody receives it.** By the documented Prometheus Operator default
   (`alertmanagerConfigMatcherStrategy: OnNamespace`), every route of an `AlertmanagerConfig` is
   **forced** to match `namespace=<where the CR lives>`: alerts from the `kafka` namespace would not
   reach a receiver defined in `monitoring`. The lab uses `type: None` and the route works (alerts
   reach the webhook). *(We did not reproduce the failure with the default.)*
3. **The Strimzi KSM starts but exports nothing.** The official `ClusterRoleBinding` ships with
   `namespace: myproject` in `subjects`, and `kustomize` **does not rewrite** `ClusterRoleBinding`
   subjects. Symptom: `customresourcedefinitions ... is forbidden` in the KSM log and zero
   `strimzi_*` metrics. Fixed in `ksm/ksm.yaml` (and documented there).
4. **Prometheus takes a while to see a new `PodMonitor` (1–3 min).** Observed: the operator generates
   the configuration Secret right away (the config already contained the `podMonitor/` jobs), but
   Prometheus only reloaded ~3 min later — consistent with the slow propagation of a Secret mounted
   as a volume. Not a bug: check `Targets` after ~2–3 min before concluding something is wrong.
5. **`kubelet_volume_stats_*` does not exist on kind.** `local-path` volumes do not report free space
   to the kubelet. The `KafkaRunningOutOfDisk` alert and the PVC panel are valid on a real cluster
   (CSI); in the lab, the dashboard uses `kafka_log_log_size` (log size, from Kafka itself). The
   *Available Disk Space* panel of the official `Strimzi Kafka` dashboard stays empty — expected.

## 5. Prerequisites

- **Docker** with **≥ 10 GB of RAM** allocated (the lab uses ~7.5 GB: 3 brokers of 1 GiB + Prometheus +
  Grafana + Tempo + ArgoCD; measured with `docker stats` on 4 kind nodes).
- `kind` 0.24+, `kubectl`, `git`, `curl`, `jq` (the charts are installed by ArgoCD, not by you).
- For the **local CI** (section 9, scenario E): `python3` and Docker (`promtool` runs in an image).
- Free host ports: **3000, 9090, 9093** (Grafana, Prometheus, Alertmanager) and 18080/8080 if you use
  the local Git / ArgoCD UI. If one is taken, change the `hostPort` in `kind-config.yaml`.
- Internet: the lab downloads charts, images and the ArgoCD manifest.

## 6. Lab layout

```text
Day10-Observabilidade/
├── README.md / README-EN.md
├── kind-config.yaml            # 1 control-plane + 3 workers; ports 3000/9090/9093 mapped to the host
├── lab/
│   ├── app/                    # app.py (the 3 roles), Dockerfile, requirements.txt
│   ├── git-server.yaml         # minimal Git INSIDE the cluster (same as Day 9) - lab only
│   └── push-repo.sh            # seeds Git and creates the working clone in lab/work/observability
└── gitops/                     # <<< the contents of the Git repository ArgoCD watches
    ├── bootstrap/              # appproject.yaml + root-app.yaml  (the ONLY manual kubectl apply)
    ├── apps/                   # 6 Applications (one per file, with sync-wave)
    ├── manifests/
    │   ├── kafka/              # Kafka, KafkaNodePool (anti-affinity), KafkaTopic
    │   ├── observability/      # podmonitors, rules/, alertmanagerconfig, datasource, ksm/, dashboards/*.json
    │   └── demo-apps/          # producer, processor, sink + PodMonitor
    ├── ci/                     # validate.sh, extract_rules.py, tests/rules_test.yml
    └── .github/                # CODEOWNERS + workflow
```

## 7. Bringing the lab up

> **How to use from here on:** every ` ```bash ` block is meant to be **copied and pasted, in order,
> into the same terminal** (zsh or bash). ` ```text ` blocks are the **expected output** — they do not
> run. Blocks starting with `: TERMINAL 2` need **a second terminal** (open it at the repo root and
> paste the `kx` function again).

**Safety:** every command uses `--context kind-strimzi-day10` (the `kx` function). Nothing is applied
outside kind, even if your `kubeconfig` has work clusters.

**Reset** (if you ran the lab before). From the **repository root**:

```bash
kind delete cluster --name strimzi-day10 2>/dev/null
pkill -f "port-forward svc/git-server" 2>/dev/null
rm -rf kafka-strimzi/Day10-Observabilidade/lab/work
echo "clean"
```

### 7.1 kind cluster and the app image

```bash
cd kafka-strimzi/Day10-Observabilidade
kind create cluster --config=kind-config.yaml --name strimzi-day10
kx() { kubectl --context kind-strimzi-day10 "$@"; }
kx wait --for=condition=Ready node --all --timeout=120s
```

The sample app is a local image (a 7-line `Dockerfile`). We build it and load it into the kind nodes:

```bash
docker build -q -t kafka-e2e-demo:0.1.0 lab/app
kind load docker-image kafka-e2e-demo:0.1.0 --name strimzi-day10
```

### 7.2 ArgoCD

Same procedure as Day 9 (ArgoCD 3.4.6; `--server-side` because the CRDs are too big for client-side
apply; 30 s reconciliation just for the lab — in production use a Git **webhook**):

```bash
kx create namespace argocd
kx apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.6/manifests/install.yaml > /dev/null
kx wait -n argocd --for=condition=Available deployment --all --timeout=300s
kx -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kx -n argocd patch cm argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"30s","timeout.reconciliation.jitter":"0s"}}'
kx -n argocd rollout restart statefulset/argocd-application-controller deploy/argocd-repo-server
kx -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kx -n argocd rollout status deploy/argocd-repo-server --timeout=300s
```

### 7.3 Local Git and bootstrap

ArgoCD needs a real Git remote. The same minimal Git server from Day 9 comes up inside the cluster
(**no authentication, lab only**) and `push-repo.sh` seeds the `observability` repo from `gitops/`,
leaving a **working clone** at `lab/work/observability` (that is where you run `git commit`/`git push`
in the scenarios):

```bash
kx apply -f lab/git-server.yaml
lab/push-repo.sh
```

```text
pushed observability -> http://git-server.git.svc/cgi-bin/git/observability.git (from inside the cluster)
```

Now the **only** `kubectl apply` of the whole platform — the `AppProject` and the `root`:

```bash
kx apply -f gitops/bootstrap/appproject.yaml -f gitops/bootstrap/root-app.yaml
```

*(Optional, great for the video)* ArgoCD UI at <https://localhost:8080> (user `admin`). **In terminal 2**:

```bash
: TERMINAL 2 — leave this command running
kubectl --context kind-strimzi-day10 -n argocd port-forward svc/argocd-server 8080:443
```

```bash
kx -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

### 7.4 Waiting for everything to come up (~3–6 min)

```bash
until kx get kafka my-cluster -n kafka >/dev/null 2>&1; do echo "waiting for ArgoCD to create Kafka..."; sleep 5; done
kx wait kafka/my-cluster -n kafka --for=condition=Ready --timeout=480s
kx -n argocd get applications
```

```text
NAME                    SYNC STATUS   HEALTH STATUS
demo-apps               Synced        Healthy
kafka                   Synced        Healthy
kube-prometheus-stack   Synced        Healthy
observability           Synced        Healthy
observability-root      Synced        Healthy
strimzi-operator        Synced        Healthy
tempo                   Synced        Healthy
```

*(`kafka` may show `Progressing` while the cluster comes up.)* One broker per node, thanks to the
`KafkaNodePool` `podAntiAffinity`:

```bash
kx -n kafka get pods -o wide | awk '{print $1, $2, $3, $7}'
```

```text
NAME                                         READY STATUS  NODE
my-cluster-dual-role-0                       1/1   Running strimzi-day10-worker3
my-cluster-dual-role-1                       1/1   Running strimzi-day10-worker2
my-cluster-dual-role-2                       1/1   Running strimzi-day10-worker
my-cluster-entity-operator-66d6858cdc-9thfn  2/2   Running strimzi-day10-worker2
my-cluster-kafka-exporter-674c8dfc8b-j8nq8   1/1   Running strimzi-day10-worker3
```

> `order-producer` may restart **once** in the first minutes (`RESTARTS 1`): it starts before Kafka
> is ready. That is expected — and a good moment to show `restarts` on the Kubernetes dashboard.

Check that Prometheus is scraping everything. **Wait ~2 min** (pitfall #4 in section 4.5):

```bash
sleep 120
curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets[] | select(.labels.job|test("kafka|strimzi|entity|order|cluster-operator|kube-state")) | "\(.health)\t\(.labels.job)"' | sort | uniq -c
```

```text
   3 up	demo/order-pipeline
   1 up	monitoring/cluster-operator-metrics
   1 up	monitoring/entity-operator-metrics
   3 up	monitoring/kafka-resources-metrics
   2 up	kube-state-metrics
```

## 8. Tour: Grafana, Prometheus, Alertmanager and ArgoCD

### 8.1 Grafana (<http://localhost:3000>, `admin` / `admin`)

The dashboards were provisioned from **ConfigMaps in Git**, in two folders:

```bash
curl -s -u admin:admin 'localhost:3000/api/search?type=dash-db' | jq -r '.[] | select(.folderTitle=="Strimzi" or .folderTitle=="Pipeline") | "\(.folderTitle)\t\(.title)"' | sort
```

```text
Pipeline	Order pipeline - end to end
Strimzi	Strimzi KRaft
Strimzi	Strimzi Kafka
Strimzi	Strimzi Kafka Exporter
Strimzi	Strimzi Operators
```

| Dashboard | What for | Origin |
|---|---|---|
| **Order pipeline - end to end** (`/d/e2e-pipeline`) | the 3 questions on one screen: business → Kafka → traces | written for this Day (`dashboards/e2e-pipeline.json`) |
| **Strimzi Kafka** | brokers: traffic, ISR, JVM, requests | official Strimzi, *Metrics Reporter* variant |
| **Strimzi KRaft** | quorum, controller leader, metadata replication | official Strimzi, *Metrics Reporter* variant |
| **Strimzi Kafka Exporter** | lag per consumer group, offsets per topic | official Strimzi |
| **Strimzi Operators** | Cluster/Topic/User Operator reconciliations | official Strimzi |

In `Order pipeline - end to end`, each stat tells you its source in the *tooltip* (the `ⓘ` icon): the
top ones are **app metrics** + Kafka Exporter lag; the bottom ones come from the **Metrics Reporter**,
the **native kube-state-metrics** and the **KSM for CRs**. On the last row, a TraceQL table lists
recent traces (click the *Trace ID* to open the waterfall).

Besides ours, `kube-prometheus-stack` ships Kubernetes dashboards
(*Compute Resources / Namespace (Pods)*, *Persistent Volumes*...) — handy for broker and pipeline
CPU/memory without writing anything.

### 8.2 Prometheus (<http://localhost:9090>)

- **Status → Targets:** the `PodMonitor`s became jobs (`monitoring/kafka-resources-metrics`, etc.).
- **Alerts:** the 5 `PrometheusRule`s (brokers, Kafka Exporter, operators, Strimzi CRs and the pipeline),
  **all inactive** on a healthy system. `Watchdog` (always firing) is the "the alerting pipeline is alive" alert.
  *Laptop gotcha:* the stock `PrometheusMissingRuleEvaluations` alert may show up as **Pending**
  in your lab. Observed here: **every** rule group triggers it — including the
  built-in `kube-prometheus-stack` ones — while each evaluation takes milliseconds. That points to the
  Docker VM running out of CPU or "sleeping" (an idle Mac), not to the lab's rules. *(Cause
  inferred, not isolated.)*
- **Graph:** useful queries for the conversation:

```promql
sum(kafka_server_replicamanager_underreplicatedpartitions)            # URP (Metrics Reporter)
sum by (consumergroup, topic) (kafka_consumergroup_lag)               # lag (Kafka Exporter)
strimzi_kafka_topic_resource_info                                      # KafkaTopic status (KSM for CRs)
demo:end_to_end_latency_seconds:p95                                    # end-to-end p95 (recording rule)
```

### 8.3 Alertmanager (<http://localhost:9093>) and the lab receiver

The repo's `AlertmanagerConfig` forwards **only** alerts labelled `team: kafka-platform` to the lab
webhook (a 20-line `Deployment` that prints every alert). To watch notifications arrive:

```bash
kx -n monitoring logs deploy/alert-webhook -f
```

> In production the route points at Slack/PagerDuty (commented examples in
> `alertmanagerconfig.yaml`; the *secret* lives in a `Secret`, never in Git).

## 9. Hands-on scenarios

Scenarios A, C, D and E change **Git**, not the cluster: that is the methodology. **In terminal 2**,
keep the local Git reachable (this is how your `git push` reaches the server inside the cluster):

```bash
: TERMINAL 2 — leave this command running
kubectl --context kind-strimzi-day10 -n git port-forward svc/git-server 18080:80
```

In the main terminal, enter the working clone and define a `git` shortcut with a lab identity:

```bash
cd lab/work/observability
lg() { git -c user.name=lab -c user.email=lab@example.com "$@"; }
```

> **Why `kubectl edit` does not work here:** ArgoCD runs with `selfHeal: true` — any manual change is
> reverted on the next reconciliation (~30 s). Changing the system = `git commit`.

### Scenario A — A slow consumer (via Git): lag, latency and alert

The processor now spends 400 ms per message while the producer sends 5/s. It can only process 2.5/s:
lag grows. Only *Git* changes:

```bash
sed -i.bak 's/name: PROCESS_MS, value: "30"/name: PROCESS_MS, value: "400"/' manifests/demo-apps/apps.yaml && rm manifests/demo-apps/apps.yaml.bak
lg diff --stat
lg commit -qam "perf: processor 400ms per message (simulating a slow downstream)"
lg push -q origin main
```

Open the **Order pipeline - end to end** dashboard
(<http://localhost:3000/d/e2e-pipeline>). Within a few minutes:

- *Throughput by stage*: the `sink` and `processor` lines peel away from the `producer` line;
- *Consumer-group lag*: climbs linearly (`order-processor` on `orders`);
- *Time spent processing*: the `processor` p95 jumps to ~800 ms;
- *End-to-end latency*: p50/p95/p99 climb (each message waits in the topic queue).

Alerts (measured in this lab: latency after ~4 min and lag right after — the wait is the rule's
`for:` plus its 2-minute window):

```bash
kx -n monitoring logs deploy/alert-webhook --tail=5
```

```text
[FIRING  ] warning  OrderPipelineEndToEndLatencyHigh: p95 end-to-end latency is 105.2s (SLO: 2s)
[FIRING  ] warning  KafkaConsumerGroupLagHigh: Group order-processor is 667 messages behind on orders
```

**Reverting is also a commit** — and it closes the loop with `RESOLVED`:

```bash
lg revert --no-edit HEAD >/dev/null && lg push -q origin main
```

```text
[RESOLVED] warning  KafkaConsumerGroupLagHigh: Group order-processor is 886 messages behind on orders
[RESOLVED] warning  OrderPipelineEndToEndLatencyHigh: p95 end-to-end latency is 120.0s (SLO: 2s)
```

> **What to point out:** no *broker* metric moved. Every panel in the "Is Kafka healthy?" section
> stays green. It was the **product** that degraded — and only the business metrics + lag saw it.

### Scenario B — Losing a broker (a Kubernetes node)

Killing the broker pod is **not** a good demo: Strimzi recreates it in seconds and the under-replication
window is too short for the alert (tested: `kafka_server_replicamanager_underreplicatedpartitions` reached a
sum of 27 during the restart, but the alert **did not fire** — `for: 30s` plus the 30 s scrape interval
do not see it — and **that is how it should be**: a quick restart must not wake anybody up). For a
*real* failure — like losing a node — cordon broker 1's node (the `local-path` volumes are pinned to the
node, so the pod cannot go anywhere else) and delete the pod. Thanks to `podAntiAffinity`, that node has
**only** that broker:

```bash
cd ../../..        # back to Day10-Observabilidade
NODE=$(kx -n kafka get pod my-cluster-dual-role-1 -o jsonpath='{.spec.nodeName}'); echo "NODE=$NODE"
kx cordon $NODE
kx -n kafka delete pod my-cluster-dual-role-1 --wait=false
```

With 2 of 3 nodes alive, the KRaft quorum and `min.insync.replicas=2` survive — the pipeline keeps
working, but **with no slack**. Within ~2 min:

```bash
kx -n kafka get pods | grep dual-role
curl -s -G localhost:9090/api/v1/query --data-urlencode 'query=ALERTS{alertstate=~"firing|pending",team="kafka-platform"}' | jq -r '.data.result[] | "\(.metric.alertstate)\t\(.metric.alertname)\t\(.metric.severity)\t\(.metric.topic // "")"' | sort | uniq -c
```

```text
my-cluster-dual-role-0   1/1   Running   0   7m27s
my-cluster-dual-role-1   0/1   Pending   0   118s
my-cluster-dual-role-2   1/1   Running   0   7m27s

   2 firing	KafkaUnderReplicatedPartitions	warning
   1 pending	KafkaNotReady	warning
   1 pending	KafkaExporterTopicUnderReplicated	warning	__consumer_offsets
   1 pending	KafkaExporterTopicUnderReplicated	warning	orders
   1 pending	KafkaExporterTopicUnderReplicated	warning	orders.processed
```

Look at the **Strimzi Kafka** dashboard (*Brokers Online* drops to 2, *Under Replicated Partitions*
rises) and **Order pipeline** (the "Kafka pods Ready" stat becomes 2). **Recover:**

```bash
kx uncordon $NODE
kx -n kafka wait pod/my-cluster-dual-role-1 --for=condition=Ready --timeout=300s
```

> **A lesson the lab taught the hard way:** in the first version, the Kafka Exporter alert was
> **per partition** — one broker down produced **60 alerts** for a single cause. It was fixed to
> aggregate per topic (`sum by (topic) (...)`, and a unit test proves that 3 under-replicated
> partitions yield **1** alert). An alert that fires 60 times for one cause trains the on-call to
> ignore the pager.

### Scenario C — An invalid `KafkaTopic`: ArgoCD says "Synced", Kafka says "no"

An "innocent" PR creates a topic with `replicas: 5` on a 3-broker cluster:

```bash
cd lab/work/observability
cat >> manifests/kafka/topics.yaml <<'EOF'
---
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: orders.audit
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 5            # a 3-broker cluster cannot place 5 replicas
EOF
lg commit -qam "feat: add orders.audit topic" && lg push -q origin main
```

The YAML is valid, Git accepts it, ArgoCD **syncs** it. But:

```bash
kx -n kafka get kafkatopic
kx -n kafka get kafkatopic orders.audit -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status} {.status.conditions[0].reason}{"\n"}{.status.conditions[0].message}{"\n"}'
kx -n argocd get app kafka
```

```text
NAME               CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
orders             my-cluster   6            3                    True
orders.audit       my-cluster   3            5                    False
orders.processed   my-cluster   6            3                    True

Ready=False KafkaError
org.apache.kafka.common.errors.InvalidReplicationFactorException: Unable to replicate the partition 5 time(s): The target replication factor of 5 cannot be reached because only 3 broker(s) are registered or some brokers have all their log directories cordoned.

NAME    SYNC STATUS   HEALTH STATUS
kafka   Synced        Progressing
```

ArgoCD shows `Synced` (the YAML *was* applied) and `Progressing` — **and stays that way forever, waking
nobody.** What wakes someone is the **KSM for CRs**:

```text
[FIRING  ] warning  KafkaTopicNotReady: Strimzi KafkaTopic orders.audit is not ready
```

(~2.5 min: ArgoCD sync + `for: 1m`.) The metric behind the alert, to show live:

```promql
strimzi_kafka_topic_resource_info{ready!="True"}
```

> **The moral:** "Git ok + ArgoCD ok" does not mean "Kafka ok". Day 8 showed that the Topic Operator
> **refuses** what it cannot do; this Day shows **how you find out**.
> Clean up: `lg revert --no-edit HEAD >/dev/null && lg push -q origin main`.

### Scenario D — Processing errors and the trace that points at the culprit

30% of orders start failing validation:

```bash
sed -i.bak 's/name: ERROR_RATE, value: "0"/name: ERROR_RATE, value: "0.3"/' manifests/demo-apps/apps.yaml && rm manifests/demo-apps/apps.yaml.bak
lg commit -qam "test: 30% of orders fail validation" && lg push -q origin main
```

In ~4 min `OrderPipelineProcessingErrors` fires (error rate > 5%). Now question #3 — *which* orders
failed? In **Grafana → Explore → Tempo** (or through the API), the TraceQL `status = error` finds
the traces with an error span:

```text
{ status = error }
```

Each error span carries the `order rejected` event and the `order.id` — you can go from the alert
(aggregate) to the specific order (individual). Clean up: `lg revert --no-edit HEAD >/dev/null && lg push -q origin main`.

### Scenario E — An alert PR, with CI

The golden rule: **every time you create or touch an alert, write/update a test.** See what the CI
catches, locally (from `Day10-Observabilidade/gitops`):

```bash
cd ../../../gitops && ci/validate.sh
```

```text
== 1. kustomize build
   OK (...)
== 3. promtool check rules
Checking /w/rules.yml
  SUCCESS: 47 rules found

== 4. promtool test rules (unit tests)
Processing test file: /w/rules_test.yml
  SUCCESS

ALL GOOD
```

**Case 1 — syntax error** (a forgotten parenthesis in the PR) is stopped before it reaches Prometheus:

```text
== 3. promtool check rules
Checking /w/rules.yml
  FAILED:
/w/rules.yml: 122:11: group "kafka-exporter", rule 1, "KafkaConsumerGroupLagHigh": could not parse expression: 1:30: parse error: unexpected "(" in grouping opts, expected "," or ")"
```

**Case 2 — valid PromQL, changed behavior.** Someone raises the lag threshold from `500` to `50000`
"to stop the noise". Syntax is fine; **the unit test fails**, because the scenario
"1400 messages of lag must alert" is no longer true:

```text
  FAILED:
    name: consumer lag is summed per group and topic (ONE alert, not one per partition),
    alertname: KafkaConsumerGroupLagHigh, time: 2m,
        exp:[ 0: Labels:{alertname="KafkaConsumerGroupLagHigh", consumergroup="order-processor", ...} ],
        got:[]
```

To change the threshold *on purpose*, the PR has to change the test too — and `CODEOWNERS` asks for a
review from whoever gets paged by the alert. That is what prevents "alert silenced by accident".

## 10. End-to-end tracing

### 10.1 What the lab delivers

Each order generates **one trace, across three services and two topics**. Real structure of a trace
(output of the Tempo API; times relative to the first span):

```text
+    0ms dur=   0ms  order-producer   create order                   INTERNAL   (root)
+    0ms dur=   0ms  order-producer   orders send                    PRODUCER
+   24ms dur=  41ms  order-processor  orders process                 CONSUMER
+   24ms dur=  41ms  order-processor  validate and enrich order      INTERNAL
+   65ms dur=   0ms  order-processor  orders.processed send          PRODUCER
+   88ms dur=  13ms  order-sink       orders.processed process       CONSUMER
+   88ms dur=  13ms  order-sink       send notification              INTERNAL
```

How to read it: the **gap** between the end of `orders send` (0 ms) and the start of `orders process`
(24 ms) is the **time the message spent in the topic** (replication + waiting for the consumer). A long
span is the *app's* work; a long gap is *queueing* (lag). In scenario A, that gap becomes **minutes**.

### 10.2 How context crosses Kafka

The W3C `traceparent` travels **in the Kafka record headers** (message metadata, not payload):

1. **Producer:** the OpenTelemetry instrumentation creates the `send` span and **injects**
   `traceparent` into the headers (`instrument_producer`).
2. **Consumer:** reads the headers, **extracts** the context and opens the `process` span **as a
   child** of `send` (the `process_span` function in `lab/app/app.py`).
3. **Next hop:** the processor calls `produce()` **inside** the `process` span — the instrumentation
   injects the *current* context and the next service continues the same trace.

```python
def process_span(msg):
    headers = {k: v.decode() for k, v in (msg.headers() or []) if isinstance(v, bytes)}
    return tracer.start_as_current_span(
        f"{msg.topic()} process", context=propagate.extract(headers), kind=SpanKind.CONSUMER, ...)
```

> **A pitfall the lab hit:** OpenTelemetry's stock *consumer* instrumentation for `confluent-kafka`
> (`instrument_consumer`) **does not continue the producer's trace** — it creates a new trace per
> message and only **links** the two with a *span link* (the "batch" model of the messaging semantic
> convention). Result in Tempo: loose traces instead of one story. That is why the consumer extracts
> the context **by hand** (the function above), which is also the best way to explain propagation on
> video. (Links are useful for *batches* — one poll with 500 messages — but the goal here is "follow
> *this* message".)

### 10.3 Querying in Grafana (Explore → Tempo)

```text
{ resource.service.name = "order-producer" }                     # every order
{ status = error }                                                # only the ones that failed
{ resource.service.name = "order-sink" && duration > 2s }         # reached the end, but slowly
```

### 10.4 What the broker does **not** show in the trace

Kafka itself **emits no spans**: in the waterfall, the broker is the gap between `send` and `process`.
That is inherent to Kafka, not to the lab. Strimzi documents OpenTelemetry tracing for
**Kafka Connect, MirrorMaker 2 and Kafka Bridge** (not exercised in this lab — section 12). For
**Java** applications, the OpenTelemetry *agent* instruments `kafka-clients` with no code change
(also not exercised here).

## 11. Going to production

| Lab | Production |
|---|---|
| Single Prometheus, 6 h retention, no disk | HA (2 replicas) + **long-term storage** (Thanos / Mimir / remote_write); size retention and cardinality |
| Kafka Exporter metrics *per partition* | watch **cardinality**: topics × partitions × groups blows up series; use `topicRegex`/`groupRegex` to limit |
| Single Alertmanager + lab webhook | HA + real receivers (Slack/PagerDuty); *secrets* in a `Secret`, **inhibitions** and silences as code |
| `for: 30s–1m` on alerts (so the lab reacts fast) | `for: 5m+` on anything that heals itself (a rolling restart causes URP for ~1 min: normal); alert on **symptoms** (lag, latency, errors), use causes (disk, ISR) as *warning* |
| Single-binary Tempo, no persistence, 100% sampling | `tempo-distributed` or Grafana Cloud, **object storage**, an **OpenTelemetry Collector** in the middle (*tail-based* sampling to keep 100% of errors and a fraction of the rest) |
| Grafana `admin/admin`, plaintext Kafka listeners | SSO, TLS/SCRAM (Day 4) — **and scraping** must know about it; `NetworkPolicy` for `/metrics` |
| `kubelet_volume_stats` missing (kind) | the disk alert (`KafkaRunningOutOfDisk`) works on a real cluster with CSI — **enable it** |
| Permissive AppProject (`*`) | restrict `sourceRepos`, `destinations` and what the project may create (commented in `appproject.yaml`) |

Three more decisions worth a conversation:

- **SLO instead of a threshold.** The `2s` in the latency alert is an example SLO. In production,
  define the SLO with the product and alert on *burn rate* — which this Day's structure (the
  `demo:end_to_end_latency_seconds:p95` recording rule) already prepares for.
- **Dashboards are code, but who edits through the UI?** The sidecar overwrites on every sync; treat
  the UI as a draft (export the JSON and open a PR).
- **Observability is part of a service's Definition of Done.** The `PodMonitor` next to the
  `Deployment` is that idea in file form.

## 12. What this lab does NOT cover (honestly)

- **The GitHub Actions workflow was not executed** (there is no GitHub in this environment). The same
  `ci/validate.sh` it calls **was run locally** (success and the two failures of scenario E). What is
  left to validate on your GitHub: permissions, check triggering, *branch protection* with Code Owners.
- **Real receivers (Slack, PagerDuty, e-mail)** were not tested — only the lab webhook. The route and
  the commented examples exist, but real delivery does not.
- **Tracing on Kafka Connect, MirrorMaker 2 and Kafka Bridge** (supported by Strimzi) and the
  OpenTelemetry **Java agent** were **not exercised**: the sample app is Python. The other Strimzi
  components (Connect, MM2, Bridge) also have **no** metrics wired in this lab.
- **`jmxPrometheusExporter` was not deployed** — only described in section 3 (the lab uses the
  Metrics Reporter). The Metrics Reporter metric *allowlist* (`metricsConfig.values.allowList`) was
  not exercised either: the lab uses the default set.
- **Cruise Control** (Day 6/7): its metrics and the `strimzi-cruise-control.json` dashboard were not
  wired in here.
- **`kubelet_volume_stats_*` does not exist on kind** (pitfall 5): the PVC free-space alert and panel
  were **not exercised** — the rule exists, but only validate it on a real cluster.
- **Multi-cluster/multi-region** was not built (one Prometheus, one Kafka). Federation or per-region
  `remote_write` is outside this Day.
- **No TLS/authentication** on Kafka, Tempo, Grafana and the lab Git. Nothing here is production
  configuration.
- **Tempo and memory:** with continuous traffic (~5 traces/s, 100% sampling) the single-binary Tempo hit its 768Mi limit and was `OOMKilled` (5 restarts in 25h) — symptom: Grafana showed `connection refused` on port 3200. The lab now uses a 1536Mi limit and 6 h retention; if you leave the lab up for days, **watch** `kube_pod_container_status_last_terminated_reason`. In production, size Tempo (or use `tempo-distributed`) and lower the sampling rate.
- **The timings** (~4 min for an alert, ~2 min for Prometheus to find a `PodMonitor`) were measured on
  Docker Desktop (Apple Silicon); on your machine they will vary.

## 13. Cleanup

```bash
kind delete cluster --name strimzi-day10
pkill -f "port-forward svc/git-server" 2>/dev/null
pkill -f "port-forward svc/argocd-server" 2>/dev/null
rm -rf lab/work lab/app/__pycache__
docker rmi kafka-e2e-demo:0.1.0 2>/dev/null
```

## 14. Suggested video script

Target duration: **~25 min**. The thread is the three questions from section 1; show them early and come back to them.

| Time | Block | What to show |
|---|---|---|
| 0:00 | Hook | "Every Kafka panel is green and the customer did not get the notification. How do you find out?" |
| 1:30 | The 3 questions | Section 1; the architecture (section 2) |
| 3:30 | Where metrics come from | The section 3 table: **6 sources**, why the Kafka Exporter and the KSM for CRs exist |
| 6:00 | GitOps live | `kx -n argocd get applications`; open `apps/` and `manifests/observability/`; "no Prometheus file was edited" |
| 8:30 | Grafana tour | The end-to-end dashboard top to bottom; then *Strimzi Kafka* |
| 11:00 | **Scenario A** | Commit that slows the processor → lag, latency, alert on the webhook → `git revert` → `RESOLVED` |
| 15:00 | **Scenario C** | PR with `replicas: 5` → ArgoCD "Synced" but topic `Ready=False` → KSM alert. "Git ok ≠ Kafka ok" |
| 18:00 | **Tracing** | Open one order's trace: 3 services, 2 topics; the gap = time in the topic; show `process_span` and the `traceparent` header |
| 21:00 | **Scenario D** | `{ status = error }` in Tempo: from the aggregate alert to the individual order |
| 22:30 | Scenario B (quick) | Node cordon → URP → "a quick restart must not wake anyone" (and the 60 per-partition alerts) |
| 24:00 | Scenario E + wrap-up | `ci/validate.sh` failing an alert PR; the section 11 checklist; Day 11 teaser (external access) |

## 15. References

- Strimzi — [official documentation (Deploying and Managing)](https://strimzi.io/docs/operators/latest/deploying), chapters *Introducing Metrics* and *Distributed tracing*, and the
  [official examples](https://github.com/strimzi/strimzi-kafka-operator/tree/1.1.0/examples/metrics)
  (`strimzi-metrics-reporter/`, `kube-state-metrics/`, `prometheus-install/`) — the dashboards, KSM and rules in this lab start from them
- [Prometheus Operator](https://prometheus-operator.dev/) — `PodMonitor`, `PrometheusRule`, `AlertmanagerConfig`
- [`promtool test rules`](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/) — unit tests for alerts
- [kube-state-metrics](https://github.com/kubernetes/kube-state-metrics) (*Custom Resource State* mode)
- [kube-prometheus-stack (chart)](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Grafana Tempo](https://grafana.com/docs/tempo/latest/) and [TraceQL](https://grafana.com/docs/tempo/latest/traceql/)
- [OpenTelemetry — messaging semantic conventions](https://opentelemetry.io/docs/specs/semconv/messaging/) and [context propagation (W3C Trace Context)](https://www.w3.org/TR/trace-context/)
- [Argo CD — App of Apps and Sync Waves](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [Day 8 — Topic and User Operator](../Day8-TopicUserOperators/) and [Day 9 — Multi-team GitOps](../Day9-GitOps-MultiTime/) (the lab Git server and `selfHeal` come from there)
