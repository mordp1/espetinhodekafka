# Kafka Node Pools no Strimzi — KRaft na Prática

> **Objetivo:** Entender como funcionam os **Kafka Node Pools** no Strimzi, separando
> `broker` e `controller` em grupos distintos, com storage persistente e um cluster
> **kind** multi-node — a configuração recomendada para produção.

---

## Índice

1. [Contexto](#1-contexto)
2. [O que são Kafka Node Pools](#2-o-que-são-kafka-node-pools)
3. [Pré-requisitos](#3-pré-requisitos)
4. [Estrutura do Lab](#4-estrutura-do-lab)
5. [Subindo o Cluster Kind (multi-node)](#5-subindo-o-cluster-kind-multi-node)
6. [Instalando o Strimzi Cluster Operator](#6-instalando-o-strimzi-cluster-operator)
7. [Deploy dos Node Pools e do Kafka](#7-deploy-dos-node-pools-e-do-kafka)
8. [Validando o Cluster](#8-validando-o-cluster)
9. [Criando Tópico e Testando Produção/Consumo](#9-criando-tópico-e-testando-produçãoconsumo)
10. [Escalando um Node Pool ao Vivo](#10-escalando-um-node-pool-ao-vivo)
11. [Outras Configs que Valem a Pena Olhar](#11-outras-configs-que-valem-a-pena-olhar)
12. [Cleanup](#12-cleanup)
13. [Referências](#13-referências)

---

## 1. Contexto

No [Day 1](../Day1-Introducao/) subimos o Strimzi mais simples possível: **1 node**
acumulando os papéis de `controller` e `broker` (dual-role), com storage `ephemeral`.
Ótimo para aprender o Operator, péssimo para produção — um único node é um único ponto de
falha, e sem storage persistente qualquer restart perde os dados.

Neste Day 2 damos o próximo passo: **Kafka Node Pools separados** — um pool só de
`controller`, outro só de `broker` — cada um com seu próprio número de réplicas, storage e
configuração, rodando num cluster kind com **múltiplos nodes** (1 control-plane + 2 workers),
para você ver os pods do Kafka de fato distribuídos entre máquinas diferentes.

## 2. O que são Kafka Node Pools

Um **`KafkaNodePool`** é um Custom Resource que representa um grupo de nodes dentro de um
cluster Kafka, cada um com um **papel** (`role`) bem definido:

| Role | Função |
|---|---|
| `broker` | Plano de dados — recebe, armazena e serve as mensagens dos tópicos |
| `controller` | Plano de controle — gerencia o metadado do cluster via **Raft** (KRaft) |
| `broker` + `controller` (dual-role) | Um único node acumula as duas funções (usado no Day 1) |

Cada `KafkaNodePool` tem seu próprio `replicas`, `roles` e `storage` — o que permite, por
exemplo, dar discos maiores/mais rápidos só para os brokers, escalar brokers e controllers
de forma independente, ou até misturar diferentes classes de storage no mesmo cluster.

> **Nota histórica:** em versões antigas do Strimzi, tanto o **KRaft** quanto os
> **Kafka Node Pools** eram recursos experimentais, escondidos atrás de *feature gates*
> (`+KRaft`, `+UseKRaft`, `+KafkaNodePools`) que você precisava habilitar manualmente no
> Cluster Operator. Hoje, na versão usada neste lab (**Strimzi 1.1.0**), os dois já são
> **GA (General Availability) e vêm ligados por padrão** — o Zookeeper foi removido do
> Strimzi a partir da versão 0.46. Você não precisa (e nem consegue mais) criar um cluster
> Kafka com Zookeeper num Strimzi atual.

Separar `broker` e `controller` em pools distintos (em vez de dual-role) deixa o conceito
mais visível: no `kubectl get pods`, você vê claramente quais pods são plano de controle e
quais são plano de dados, e pode escalar cada um de forma independente — como fazemos na
[seção 10](#10-escalando-um-node-pool-ao-vivo).

## 3. Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) com pelo menos ~4GB de RAM livres
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Ter feito o [Day 1](../Day1-Introducao/) (recomendado, não obrigatório)

## 4. Estrutura do Lab

```
Day2-NodePools/
├── kind-config.yaml                # cluster kind: 1 control-plane + 2 workers
├── kafka-nodepool-controller.yaml  # KafkaNodePool "controller" (3 réplicas)
├── kafka-nodepool-broker.yaml      # KafkaNodePool "broker" (3 réplicas)
├── kafka-cluster.yaml              # Kafka CR (RF=3, min.insync.replicas=2)
├── kafka-topic-example.yaml        # KafkaTopic de teste (3 partições, RF 3)
├── README.md
└── README-EN.md
```

## 5. Subindo o Cluster Kind (multi-node)

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day2
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

Confirme os 3 nodes:

```bash
kubectl get nodes -o wide
```

## 6. Instalando o Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 7. Deploy dos Node Pools e do Kafka

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

Cada `KafkaNodePool` usa storage `persistent-claim` (JBOD, 5Gi, `deleteClaim: true` — para o
cleanup remover as PVCs automaticamente quando o cluster for deletado):

```yaml
# kafka-nodepool-broker.yaml (a mesma estrutura vale para o controller.yaml)
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

## 8. Validando o Cluster

```bash
kubectl get kafkanodepool -n kafka
kubectl get pods -n kafka -o wide
kubectl get pvc -n kafka
```

Saída real deste lab (rodando neste momento):

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

Repare em duas coisas:

- Os `NODEIDS` do pool `broker` (`0,1,2`) e do `controller` (`3,4,5`) **não se repetem** —
  cada node do cluster Kafka (independente do pool) tem um ID único.
- Os pods aparecem espalhados entre `strimzi-day2-worker` e `strimzi-day2-worker2` — o
  Kubernetes distribuiu os 6 pods entre os 2 workers do cluster.

## 9. Criando Tópico e Testando Produção/Consumo

```bash
kubectl apply -f kafka-topic-example.yaml -n kafka
kubectl get kafkatopic -n kafka
```

**Produzir:**

```bash
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
```

**Consumir** (em outro terminal):

```bash
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning
```

## 10. Escalando um Node Pool ao Vivo

Uma das grandes vantagens dos Node Pools: escalar brokers e controllers **de forma
independente**, sem tocar no resto do cluster. O `KafkaNodePool` suporta o subresource
`/scale`, então dá pra usar `kubectl scale` direto:

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka
```

Acompanhe o novo broker subir:

```bash
kubectl get kafkanodepool broker -n kafka
kubectl get pods -n kafka -o wide | grep broker
```

Resultado real deste lab — o novo broker recebeu automaticamente o próximo `nodeId` livre
(`6`, já que `3`, `4` e `5` pertencem ao pool `controller`):

```
NAME     DESIRED REPLICAS   ROLES        NODEIDS
broker   4                  ["broker"]   [0,1,2,6]
```

```
my-cluster-broker-6   1/1   Running   strimzi-day2-worker
```

O cluster continua `Ready` durante todo o processo — sem downtime, sem rebalanceamento
manual, sem editar o `Kafka` CR. Para voltar ao tamanho original:

```bash
kubectl scale kafkanodepool broker --replicas=3 -n kafka
```

## 11. Outras Configs que Valem a Pena Olhar

Fica de gancho para explorar (e para os próximos vídeos da série):

- **JBOD multi-volume** — um `KafkaNodePool` pode ter mais de um volume em `storage.volumes`
  (discos diferentes para o log de dados e para o metadado do KRaft, por exemplo).
- **`resources` / `limits`** — CPU e memória por pool, permitindo dimensionar brokers e
  controllers de forma diferente.
- **Rack awareness** (`rack.topologyKey`) — espalha réplicas entre zonas de disponibilidade.
- **Tiered Storage** — offload de segmentos antigos para object storage (S3, GCS...).
- **`KafkaUser` + autenticação** (SCRAM/TLS) — este lab não tem autenticação habilitada de
  propósito, para manter o escopo enxuto; é o assunto natural do próximo Day da série.

## 12. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # devem sumir sozinhas por causa do deleteClaim: true
kind delete cluster --name strimzi-day2
```

## 13. Referências

| Recurso | URL |
|---|---|
| Strimzi Quickstarts | https://strimzi.io/quickstarts/ |
| Strimzi Deploying Guide (Node Pools, KRaft) | https://strimzi.io/docs/operators/latest/deploying |
| KIP-500 / KRaft | https://cwiki.apache.org/confluence/display/KAFKA/KIP-500 |
| kind | https://kind.sigs.k8s.io/ |
| Repositório de exemplos do Strimzi | https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples/kafka |
| Release usada neste lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Parte da série **Espetinho de Kafka** — Strimzi Day 2: Kafka Node Pools.
> Próximo Day: autenticação e autorização (SCRAM/TLS + ACLs) com `KafkaUser`.
