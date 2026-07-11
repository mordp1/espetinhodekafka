# Kafka Node Pools no Strimzi — Avançado

> **Objetivo:** Ir além do básico dos [Kafka Node Pools](../Day2-NodePools/) explorando
> **gestão de node IDs**, **storage e scheduling diferenciados por pool** e os **padrões de
> quorum de controller no KRaft** — baseado na série de 5 posts que o próprio time do
> Strimzi publicou quando o recurso ainda era experimental.

---

## Índice

1. [Contexto](#1-contexto)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Estrutura do Lab](#3-estrutura-do-lab)
4. [Subindo o Cluster (com Zonas Simuladas)](#4-subindo-o-cluster-com-zonas-simuladas)
5. [Instalando o Strimzi Cluster Operator](#5-instalando-o-strimzi-cluster-operator)
6. [Deploy: 3 Node Pools com Storage e Scheduling Diferentes](#6-deploy-3-node-pools-com-storage-e-scheduling-diferentes)
7. [Validando Scheduling por Zona e Storage por Pool](#7-validando-scheduling-por-zona-e-storage-por-pool)
8. [Tópico e Produção/Consumo](#8-tópico-e-produçãoconsumo)
9. [Gestão de Node IDs](#9-gestão-de-node-ids)
10. [Padrões de Controller Quorum no KRaft](#10-padrões-de-controller-quorum-no-kraft)
11. [De Feature Gate a GA — o que Mudou desde 2023](#11-de-feature-gate-a-ga--o-que-mudou-desde-2023)
12. [Cleanup](#12-cleanup)
13. [Referências](#13-referências)

---

## 1. Contexto

No [Day 2](../Day2-NodePools/) separamos `broker` e `controller` em Node Pools distintos e
escalamos um pool ao vivo. Isso cobre o essencial, mas o Strimzi Node Pools tem bem mais
profundidade — documentada pelo próprio time do Strimzi numa série de 5 posts, escritos
ainda em 2023 quando o recurso era **alpha**, escondido atrás de feature gates:

1. [Introduction](https://strimzi.io/blog/2023/08/14/kafka-node-pools-introduction/) — o que é e por que existe
2. [Node ID Management](https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/) — como os IDs são atribuídos e reaproveitados
3. [Storage and Scheduling](https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/) — configuração diferente por pool
4. [Supporting KRaft](https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/) — padrões de quorum de controller
5. [What's Next](https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/) — o roadmap da época (feature gate → beta → GA)

Este Day 3 reproduz e valida, na prática, os pontos centrais desses 5 posts — inclusive
mostrando o que aconteceu quando esse roadmap de 2023 virou realidade no **Strimzi 1.1.0**
que estamos usando (seção 11).

## 2. Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) com pelo menos ~4GB de RAM livres
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Ter feito o [Day 2](../Day2-NodePools/) (recomendado — aqui já assumimos que você conhece
  o conceito básico de `KafkaNodePool`)

## 3. Estrutura do Lab

```
Day3-NodePools-Avancado/
├── kind-config.yaml                  # cluster kind: 1 control-plane + 2 workers
├── kafka-nodepool-controller.yaml    # KafkaNodePool "controller" (3 réplicas)
├── kafka-nodepool-broker-zone1.yaml  # KafkaNodePool "broker-zone1" (2 réplicas, 5Gi, pinado na zone1)
├── kafka-nodepool-broker-zone2.yaml  # KafkaNodePool "broker-zone2" (2 réplicas, 8Gi, pinado na zone2)
├── kafka-cluster.yaml                # Kafka CR (RF=3, min.insync.replicas=2)
├── kafka-topic-example.yaml          # KafkaTopic de teste (4 partições, RF 3)
├── README.md
└── README-EN.md
```

## 4. Subindo o Cluster (com Zonas Simuladas)

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day3
```

Para demonstrar scheduling por zona sem precisar de um cloud provider de verdade, rotulamos
os dois workers do kind como se fossem zonas de disponibilidade diferentes:

```bash
kubectl label node strimzi-day3-worker  topology.kubernetes.io/zone=zone1 --overwrite
kubectl label node strimzi-day3-worker2 topology.kubernetes.io/zone=zone2 --overwrite
```

## 5. Instalando o Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploy: 3 Node Pools com Storage e Scheduling Diferentes

O post [Storage and Scheduling](https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/)
mostra que cada `KafkaNodePool` pode ter seu próprio storage (tamanho/classe) e sua própria
regra de scheduling via `.spec.template.pod.affinity` — em vez de uma configuração única
para o cluster todo. Reproduzimos isso com 2 pools de broker, cada um "preso" numa zona e
com um tamanho de disco diferente:

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
        size: 5Gi                 # zone1: disco menor
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

`kafka-nodepool-broker-zone2.yaml` é idêntico, trocando `zone1` → `zone2` e `size: 5Gi` →
`size: 8Gi` (simulando um tier de storage diferente por zona).

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker-zone1.yaml -n kafka
kubectl apply -f kafka-nodepool-broker-zone2.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
```

## 7. Validando Scheduling por Zona e Storage por Pool

```bash
kubectl get kafkanodepool -n kafka
kubectl get pods -n kafka -o wide
kubectl get pvc -n kafka -o custom-columns=NAME:.metadata.name,SIZE:.status.capacity.storage,STATUS:.status.phase
```

Saída real deste lab:

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
data-0-my-cluster-broker-zone2-2   8Gi    Bound   ← storage diferente por pool ✓
data-0-my-cluster-broker-zone2-3   8Gi    Bound
```

Os dois brokers de `broker-zone1` **só** foram parar no node rotulado `zone1`, os de
`broker-zone2` **só** no `zone2` — o `nodeAffinity` por pool funcionou exatamente como o
post descreve. O `controller` (sem afinidade configurada) ficou livre para o Kubernetes
espalhar entre os dois workers.

## 8. Tópico e Produção/Consumo

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

## 9. Gestão de Node IDs

O post [Node ID Management](https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/)
explica que, por padrão, o Strimzi atribui IDs **sequenciais e globais** entre todos os
pools do cluster (repare acima: `broker-zone1` ficou com `[0,1]`, `broker-zone2` com
`[2,3]` e `controller` com `[4,5,6]` — nenhum ID se repete entre pools).

### 9.1 Escolhendo o próximo ID com `strimzi.io/next-node-ids`

Para controlar qual ID um novo node vai receber ao escalar (em vez de deixar o Strimzi
escolher o próximo sequencial), anote o pool antes de escalar:

```bash
kubectl annotate kafkanodepool broker-zone1 strimzi.io/next-node-ids="[100-109]" -n kafka
kubectl scale kafkanodepool broker-zone1 --replicas=3 -n kafka
```

Resultado real deste lab — o novo node recebeu o **menor ID disponível dentro do range**
informado (`100`), e não o `2` que seria o próximo sequencial global:

```
NAME           DESIRED REPLICAS   ROLES        NODEIDS
broker-zone1   3                  ["broker"]   [0,1,100]
```

### 9.2 Escolhendo qual node remover com `strimzi.io/remove-node-ids`

Por padrão, ao escalar para baixo o Strimzi remove o **maior ID**. Para escolher outro node
específico:

```bash
kubectl annotate kafkanodepool broker-zone1 strimzi.io/remove-node-ids="[100]" -n kafka
kubectl scale kafkanodepool broker-zone1 --replicas=2 -n kafka
kubectl annotate kafkanodepool broker-zone1 strimzi.io/remove-node-ids- -n kafka  # remove a annotation depois
```

> **Achado real deste lab (e o motivo pelo qual vale gravar isso no vídeo):** na primeira
> tentativa, tentamos remover o node `0` em vez do `100`. O Strimzi **recusou**:
>
> ```
> WARN  KafkaClusterCreator: Cannot scale down brokers [0] because [0] have assigned partition-replicas
> WARN  KafkaClusterCreator: Reverting scale-down of KafkaNodePool broker-zone1 by changing number of replicas to 3
> ```
>
> O Strimzi **nunca remove um broker que ainda tem réplicas de partição atribuídas** —
> ele reverte o `replicas` sozinho para proteger seus dados. Confirmamos com
> `kafka-topics.sh --describe` que o node `100` não tinha nenhuma réplica (tinha acabado de
> entrar no cluster), removemos ele em vez do `0`, e funcionou. Isso é uma rede de segurança
> real do operator — em produção, mover réplicas para fora de um broker antes de removê-lo
> (manualmente ou via Cruise Control) é obrigatório.

### 9.3 Limite de IDs e `reserved.broker.max.id`

Por padrão o Kafka só aceita IDs de **0 a 999** (`reserved.broker.max.id`). Se você quiser
usar ranges de ID maiores (ex: `[10000-10099]`), precisa primeiro aumentar esse limite no
`config` do `Kafka` CR.

## 10. Padrões de Controller Quorum no KRaft

O post [Supporting KRaft](https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/)
descreve 3 formas de organizar `broker` e `controller` nos Node Pools — todo cluster KRaft
precisa de **pelo menos um pool com `controller`** e **pelo menos um pool com `broker`**:

| Padrão | Como fica | Quando usar |
|---|---|---|
| **Combined (dual-role)** | 1 pool só, `roles: [controller, broker]` | Labs, dev — foi o que fizemos no [Day 1](../Day1-Introducao/) |
| **Dedicated (dedicado)** | 1 pool só `controller` + 1+ pools só `broker` | Produção — o que fizemos no [Day 2](../Day2-NodePools/) e aqui |
| **Hybrid** | Mistura de pools dual-role e pools broker-only | Migração gradual entre os dois modelos acima |

**Recomendação para o número de controllers:** um número **ímpar** — `3` ou `5` — porque o
KRaft usa consenso via **Raft**, que precisa de maioria (`quorum`) para eleger um líder de
metadado. Com um número par você desperdiça um node sem ganhar tolerância a falha extra
(3 controllers tolera 1 falha; 4 também tolera só 1, mas com 1 node a mais rodando à toa).

## 11. De Feature Gate a GA — o que Mudou desde 2023

O último post da série, [What's Next](https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/)
(setembro de 2023), traçou um roadmap para o recurso. Veja o que foi prometido e o que
realmente aconteceu, comparando com o Strimzi **1.1.0** que usamos neste lab:

| Prometido em 2023 | Realidade no Strimzi 1.1.0 (hoje) |
|---|---|
| Feature gate `+KafkaNodePools` vira **beta** e default na 0.39 | ✅ Aconteceu — e foi além |
| Feature gate vira **GA** na 0.41 | ✅ Node Pools é GA, sem feature gate nenhum |
| Zookeeper continuaria existindo por mais tempo | ❌ **Removido por completo** na 0.46 — só existe KRaft |
| Nova API `v1` sem os campos de Zookeeper/replicas/storage do `Kafka` | ✅ É exatamente a API `kafka.strimzi.io/v1` que usamos em todos os manifestos deste lab |
| Cluster sem `KafkaNodePool` continuaria funcionando via "pool virtual" | Não se aplica mais — todo cluster precisa de `KafkaNodePool` explícito hoje |

Ou seja: o que em 2023 era um recurso **alpha**, escondido atrás de feature gate e convivendo
com Zookeeper como legado, hoje é simplesmente **a única forma de rodar Kafka no Strimzi**.

## 12. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # devem sumir sozinhas por causa do deleteClaim: true
kind delete cluster --name strimzi-day3
```

## 13. Referências

| Recurso | URL |
|---|---|
| Kafka Node Pools — Introduction | https://strimzi.io/blog/2023/08/14/kafka-node-pools-introduction/ |
| Kafka Node Pools — Node ID Management | https://strimzi.io/blog/2023/08/23/kafka-node-pools-node-id-management/ |
| Kafka Node Pools — Storage and Scheduling | https://strimzi.io/blog/2023/08/28/kafka-node-pools-storage-and-scheduling/ |
| Kafka Node Pools — Supporting KRaft | https://strimzi.io/blog/2023/09/11/kafka-node-pools-supporting-kraft/ |
| Kafka Node Pools — What's Next | https://strimzi.io/blog/2023/09/18/kafka-node-pools-whats-next/ |
| Strimzi Deploying Guide | https://strimzi.io/docs/operators/latest/deploying |
| Release usada neste lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Parte da série **Espetinho de Kafka** — Strimzi Day 3: Kafka Node Pools Avançado.
> Próximo Day: autenticação e autorização (SCRAM/TLS + ACLs) com `KafkaUser`.
