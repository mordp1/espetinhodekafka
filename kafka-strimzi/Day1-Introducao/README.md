# Strimzi Operator — Kafka no Kubernetes

> **Vídeo:** [Strimzi Operator - Kafka no Kubernetes](https://www.youtube.com/watch?v=Sw8seG0h3q8)
> **Objetivo:** Entender o que é o Strimzi Operator, por que ele existe, e subir o primeiro
> cluster Kafka no Kubernetes usando **kind** na sua máquina local.

---

## Índice

1. [O que é o Strimzi](#1-o-que-é-o-strimzi)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Estrutura do Lab](#3-estrutura-do-lab)
4. [Subindo o Cluster Kind](#4-subindo-o-cluster-kind)
5. [Instalando o Strimzi Cluster Operator](#5-instalando-o-strimzi-cluster-operator)
6. [Deploy do Kafka](#6-deploy-do-kafka)
7. [Criando um Tópico](#7-criando-um-tópico)
8. [Testando Produção e Consumo](#8-testando-produção-e-consumo)
9. [Cleanup](#9-cleanup)
10. [Referências](#10-referências)

---

## 1. O que é o Strimzi

O **Strimzi** é um operator para rodar o **Apache Kafka** no **Kubernetes**. Ele segue o
[padrão Operator](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/): você
descreve o cluster Kafka que quer (quantos brokers, quantos controllers, storage, listeners,
tópicos, usuários...) em manifestos YAML declarativos (**Custom Resources**), e o Strimzi
Cluster Operator cuida de criar, atualizar e manter tudo isso rodando dentro do cluster.

**Sem o Strimzi**, rodar Kafka no Kubernetes exige gerenciar manualmente StatefulSets,
Services, ConfigMaps, Secrets, rolling updates de configuração, certificados TLS, etc.
**Com o Strimzi**, isso vira um punhado de Custom Resources:

| Custom Resource | Para que serve |
|---|---|
| `Kafka` | Define o cluster Kafka (versão, listeners, configs) |
| `KafkaNodePool` | Define um grupo de nodes do cluster (brokers e/ou controllers) — vamos explorar isso a fundo no Day 2 |
| `KafkaTopic` | Cria/gerencia tópicos via o Topic Operator |
| `KafkaUser` | Cria usuários e credenciais via o User Operator |

Neste Day 1, usamos a configuração mais simples possível: **um único node** fazendo o papel
de broker e controller ao mesmo tempo (`roles: [controller, broker]` — chamado de
**dual-role**), com storage `ephemeral` (não persiste em disco — perfeito para aprender sem
se preocupar com storage ainda). No **Day 2**, vamos separar broker e controller em
**Kafka Node Pools** distintos e usar storage persistente — a configuração recomendada para
produção.

> **Nota:** o Strimzi já não usa mais o Zookeeper — desde a versão 0.46, todo cluster roda em
> **KRaft** (Kafka Raft metadata mode) por padrão. Você vai notar que não existe nenhum
> `KafkaNodePool` do tipo "zookeeper" nos manifestos abaixo — isso não existe mais.

## 2. Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (`kind version` para conferir)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- ~4GB de RAM livres para o Docker

## 3. Estrutura do Lab

```
Day1-Introducao/
├── kind-config.yaml          # cluster kind single-node
├── kafka-single-node.yaml    # KafkaNodePool dual-role + Kafka CR
├── kafka-topic-example.yaml  # KafkaTopic de teste
├── README.md
└── README-EN.md
```

## 4. Subindo o Cluster Kind

```bash
kind create cluster --config kind-config.yaml --name strimzi-day1
```

Isso cria um cluster Kubernetes local de 1 node (control-plane) rodando dentro de um
container Docker, já com uma `StorageClass` padrão (`standard`, via
[local-path-provisioner](https://github.com/rancher/local-path-provisioner)).

Confirme que o contexto do `kubectl` apontou para o cluster novo:

```bash
kubectl cluster-info --context kind-strimzi-day1
```

## 5. Instalando o Strimzi Cluster Operator

Criamos o namespace onde tudo vai viver:

```bash
kubectl create namespace kafka
```

Instalamos o Cluster Operator a partir do manifesto oficial de uma versão **fixada**
(evita que o lab quebre se o Strimzi lançar uma versão nova depois do vídeo). O manifesto
usa `myproject` como namespace placeholder — trocamos por `kafka` com `sed` antes de aplicar:

```bash
curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka
```

Acompanhe o operator subir:

```bash
kubectl get pod -n kafka --watch
```

Espere ficar `Running` (Ctrl+C para sair do watch), ou use:

```bash
kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploy do Kafka

O arquivo [`kafka-single-node.yaml`](kafka-single-node.yaml) tem dois recursos: o
`KafkaNodePool` (1 réplica, `roles: [controller, broker]`, storage `ephemeral`) e o `Kafka`
(versão 4.3.0, listeners `plain` + `tls` internos, fatores de replicação 1 — coerente com um
único node).

```bash
kubectl apply -f kafka-single-node.yaml -n kafka
```

Aguarde o cluster ficar pronto (pode levar de 1 a 3 minutos):

```bash
kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

Confira os pods e os node pools:

```bash
kubectl get pods -n kafka
kubectl get kafkanodepool -n kafka
```

Saída esperada (resumida):

```
NAME                          READY   STATUS    RESTARTS   AGE
my-cluster-dual-role-0        1/1     Running   0          90s
my-cluster-entity-operator-…  2/2     Running   0          40s
strimzi-cluster-operator-…    1/1     Running   0          3m

NAME        DESIRED REPLICAS   ROLES                     NODEIDS
dual-role   1                  ["controller","broker"]   [0]
```

Repare no `ROLES`: o mesmo node (`nodeId 0`) acumula `controller` e `broker` — é o que
significa "dual-role". Isso é o **KRaft** rodando sem Zookeeper.

## 7. Criando um Tópico

```bash
kubectl apply -f kafka-topic-example.yaml -n kafka
kubectl get kafkatopic -n kafka
```

## 8. Testando Produção e Consumo

**Produzir mensagens** (Ctrl+D ou Ctrl+C para encerrar o producer depois de digitar):

```bash
kubectl -n kafka run kafka-producer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-producer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic
```

**Consumir mensagens** (em outro terminal):

```bash
kubectl -n kafka run kafka-consumer -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-console-consumer.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic my-topic --from-beginning
```

As mensagens digitadas no producer devem aparecer no consumer.

## 9. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl -n kafka delete -f kafka-topic-example.yaml
kind delete cluster --name strimzi-day1
```

## 10. Referências

| Recurso | URL |
|---|---|
| Strimzi Quickstarts | https://strimzi.io/quickstarts/ |
| Strimzi Deploying Guide | https://strimzi.io/docs/operators/latest/deploying |
| Strimzi — Overview | https://strimzi.io/docs/operators/latest/overview |
| kind | https://kind.sigs.k8s.io/ |
| Repositório de exemplos do Strimzi | https://github.com/strimzi/strimzi-kafka-operator/tree/main/examples |

---

> Parte da série **Espetinho de Kafka** — Strimzi Day 1: Introdução ao Operator.
> No **Day 2**, separamos broker e controller em **Kafka Node Pools** distintos, usamos
> storage persistente e um cluster kind multi-node — a configuração recomendada para produção.
