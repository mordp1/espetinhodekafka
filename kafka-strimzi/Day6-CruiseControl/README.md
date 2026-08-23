# Cruise Control no Strimzi — Introdução e Deploy

> **Objetivo:** apresentar o **Cruise Control** — a mesma ferramenta que o LinkedIn criou
> para operar Kafka em escala, hoje embutida no Strimzi como um Custom Resource — sem
> ainda executar nenhuma tarefa de rebalanceamento de verdade. Este Day é
> **conceitual e de deploy**: o que o Cruise Control é, por que ele existe, como o Strimzi
> o integra, e como confirmar que ele está rodando no seu cluster. A parte prática —
> gerar uma carga real, pedir uma proposta de rebalanceamento, aprovar e executar,
> escalar/reduzir com segurança, self-healing e o catálogo completo de goals — é o
> [Day 7](../Day7-CruiseControl-Avancado/), de propósito: você só deveria colocar a mão
> numa ferramenta que move partições de produção depois de entender o que ela é.

---

## Índice

1. [Contexto](#1-contexto)
2. [O que é o Cruise Control](#2-o-que-é-o-cruise-control)
3. [Pré-requisitos](#3-pré-requisitos)
4. [Estrutura do Lab](#4-estrutura-do-lab)
5. [Subindo o Cluster Kind](#5-subindo-o-cluster-kind)
6. [Instalando o Strimzi Cluster Operator](#6-instalando-o-strimzi-cluster-operator)
7. [Deploy: Kafka + Node Pools + Cruise Control](#7-deploy-kafka--node-pools--cruise-control)
8. [Goals: Visão Geral (Hard vs Soft)](#8-goals-visão-geral-hard-vs-soft)
9. [Cleanup](#9-cleanup)
10. [E Agora? O Que Vem no Day 7](#10-e-agora-o-que-vem-no-day-7)
11. [Referências](#11-referências)

---

## 1. Contexto

No [Day 2](../Day2-NodePools/) escalamos um `KafkaNodePool` com `kubectl scale` e o novo
broker simplesmente ficou lá, vazio — nenhuma partição existente se moveu para ele. No
[Day 3](../Day3-NodePools-Avancado/), tentamos remover um broker específico via
`strimzi.io/remove-node-ids` e o Strimzi **recusou** porque aquele node ainda tinha réplicas
de partição atribuídas — tivemos que escolher manualmente um node "vazio" para remover.

As duas situações apontam para o mesmo buraco: **nem o Strimzi nem o Kafka movem dados
automaticamente quando a topologia do cluster muda.** Escalar não rebalanceia. Reduzir
exige que você (ou alguma ferramenta) já tenha esvaziado o broker antes. Em produção, fazer
isso manualmente com `kafka-reassign-partitions.sh` é tedioso, arriscado e não pensa em
throughput de rede/disco enquanto move dados — você decide na mão quais réplicas mover, em
que ordem, sem visibilidade real de quanto cada broker já está usando de CPU/disco/rede. É
exatamente esse buraco que o **Cruise Control** fecha.

Este Day fica só na apresentação: o que a ferramenta é, como ela pensa, e como ela aparece
no seu cluster assim que você liga o CR. Botar a mão de verdade — gerar carga, pedir
proposta, aprovar, escalar com segurança — é o [Day 7](../Day7-CruiseControl-Avancado/).

## 2. O que é o Cruise Control

O [Cruise Control](https://github.com/linkedin/cruise-control) é um sistema de operação
autônoma para Kafka, criado pelo LinkedIn e mantido hoje como projeto
open source independente em [cruise-control-for-kafka/cruise-control](https://github.com/cruise-control-for-kafka/cruise-control)
(fork ativo que deu sequência ao projeto original do LinkedIn). Internamente ele é dividido
em quatro componentes que rodam em pipeline contínuo:


```
Metrics Reporter (nos brokers)
        │  publica métricas em tópicos internos
        ▼
  Load Monitor  ──►  Analyzer  ──►  Anomaly Detector  ──►  Executor
  (constrói o        (aplica os      (detecta violação      (move réplicas
   modelo de          goals e         de goal, falha de       de fato, com
   carga do            gera a         broker/disco, etc.       throttling e
   cluster)            proposta)      — dispara self-healing)  concorrência
                                                                controlados)
```

- **Load Monitor** — consome métricas (CPU, disco, bytes-in/out por partição, tamanho de
  réplica) publicadas pelo Metrics Reporter plugado nos brokers e constrói um **modelo de
  carga do cluster** em janelas de amostragem.
- **Analyzer** — a partir do modelo, calcula **propostas de otimização**: quais réplicas
  mover, de qual broker para qual broker, para satisfazer um conjunto ordenado de **goals**
  (seção 8).
- **Anomaly Detector** — monitora continuamente o cluster em busca de anomalias (broker
  caiu, disco falhou, um goal foi violado) e, se self-healing estiver habilitado para aquele
  tipo, aciona o Executor automaticamente ([Day 7](../Day7-CruiseControl-Avancado/)).
- **Executor** — de fato move os dados, respeitando limites de concorrência e throttle de
  rede/disco configuráveis ([Day 7](../Day7-CruiseControl-Avancado/)).

Todo esse estado — amostras de métricas, modelo de carga treinado, resultado de propostas —
é persistido em **três tópicos internos** que o próprio Strimzi cria ao habilitar o Cruise
Control: `strimzi.cruisecontrol.metrics`, `strimzi.cruisecontrol.modeltrainingsamples` e
`strimzi.cruisecontrol.partitionmetricsamples`. Isso importa na prática: se você apagar
esses tópicos manualmente ou zerar a retenção deles, o Cruise Control perde o histórico e
volta a pedir para "esperar as janelas de amostragem" (o [blog original do Strimzi sobre
Cruise Control](https://strimzi.io/blog/2020/06/15/cruise-control/) explica bem essa
mecânica de amostragem contínua).

O Strimzi **não empacota** o Cruise Control como um binário à parte que você precisa
instalar e configurar sozinho (nem exige o `capacityJBOD.json` manual que o projeto upstream
pede) — ele é um Custom Resource de primeira classe:

| Custom Resource | Para que serve |
|---|---|
| `Kafka.spec.cruiseControl` | Liga o Cruise Control para o cluster — o operator sobe o deployment, injeta o Metrics Reporter nos brokers, cria os tópicos internos de métricas e **deriva a capacidade de disco automaticamente** a partir do tamanho dos volumes dos `KafkaNodePool` (upstream exige um JSON manual para isso) |
| `KafkaRebalance` | Pede uma proposta de rebalanceamento (ou dispara a execução dela) — o objeto central do [Day 7](../Day7-CruiseControl-Avancado/) |

> **Por que isso importa em produção:** rebalancear "na mão" com
> `kafka-reassign-partitions.sh` significa você mesmo decidir quais réplicas mover e em que
> ordem, sem noção real de quanto disco/rede/CPU cada broker já está usando — é fácil
> saturar a rede do cluster movendo dados demais de uma vez, ou mover réplica para o broker
> errado e piorar o desbalanceamento. O Cruise Control resolve isso com throttling de
> movimentação de dados embutido e goals que enxergam o cluster inteiro de uma vez. A
> [Red Hat Streams for Apache Kafka](https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str)
> resume bem esse mesmo racional em modo KRaft: o Cruise Control monitora carga de disco,
> CPU e rede continuamente e usa isso pra decidir *o quê* mover, não só *que* mover é
> necessário.

## 3. Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) com pelo menos ~6GB de RAM livres (4 nodes
  kind + Cruise Control + Kafka rodando ao mesmo tempo)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
- Ter feito o [Day 2](../Day2-NodePools/) e o [Day 3](../Day3-NodePools-Avancado/)
  (assumimos que você já escalou um `KafkaNodePool` e já viu o Strimzi recusar um
  scale-down inseguro — é exatamente essa dor que o Cruise Control resolve)

## 4. Estrutura do Lab

```
Day6-CruiseControl/
├── kind-config.yaml                  # cluster kind: 1 control-plane + 3 workers
├── kafka-nodepool-controller.yaml    # KafkaNodePool "controller" (3 réplicas)
├── kafka-nodepool-broker.yaml        # KafkaNodePool "broker" (3 réplicas, 10Gi)
├── kafka-cluster.yaml                # Kafka CR com cruiseControl habilitado
├── README.md
└── README-EN.md
```

Sem carga de trabalho, sem `KafkaRebalance` — este Day só sobe o cluster e mostra o Cruise
Control vivo. Os manifests de carga multi-tópico e os três modos de `KafkaRebalance`
(`full`, `add-brokers`, `remove-brokers`) moraram aqui antes, mas agora vivem no
[Day 7](../Day7-CruiseControl-Avancado/), junto com o resto do fluxo prático.

## 5. Subindo o Cluster Kind

Usamos **3 workers** neste Day (em vez de 2, como nos Days 2/3) para já deixar o ambiente
pronto para o [Day 7](../Day7-CruiseControl-Avancado/), que precisa desse espaço extra para
escalar de 3 para 4 brokers:

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day6
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

## 7. Deploy: Kafka + Node Pools + Cruise Control

O único diferencial do [`kafka-cluster.yaml`](kafka-cluster.yaml) deste lab em relação ao
Day 2 é o bloco `cruiseControl`:

```yaml
spec:
  # ...listeners, config, entityOperator iguais ao Day 2...
  cruiseControl:
    config:
      self.healing.broker.failure.enabled: "true"
```

Isso é tudo que você precisa no `Kafka` CR — o Strimzi cuida do resto (deployment do
Cruise Control, RBAC, tópicos internos de métricas, configuração do Metrics Reporter nos
brokers). É literalmente a diferença entre "instalar e configurar o Cruise Control puro"
(o que a [documentação oficial do Strimzi sobre deploy](https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str)
descreve com mais detalhe) e só ligar uma chave num CR que você já tem.

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
kubectl get pods -n kafka
```

Você deve ver, além dos pods de broker/controller, um pod extra:

```
my-cluster-cruise-control-<hash>   1/1   Running
```

Esse pod já é o Cruise Control completo — Load Monitor, Analyzer, Anomaly Detector e
Executor rodando dentro dele, amostrando métricas desde o primeiro segundo, mesmo sem
nenhum `KafkaRebalance` aplicado ainda. Confirme que ele está de fato coletando estado:

```bash
kubectl logs -n kafka deployment/my-cluster-cruise-control --tail=20
kubectl get kafkatopic -n kafka
```

Repare nos três tópicos internos criados automaticamente
(`strimzi.cruisecontrol.metrics`, `strimzi.cruisecontrol.modeltrainingsamples`,
`strimzi.cruisecontrol.partitionmetricsamples`) — é o Load Monitor já em ação, mesmo sem
nenhuma tarefa de rebalanceamento pedida ainda.

> **Detalhe de segurança que passa despercebido:** a API REST do Cruise Control expõe
> operações potencialmente destrutivas (decomissionar broker, mover réplica em massa). Por
> isso o Strimzi já sobe o Cruise Control com **HTTP Basic Auth + TLS habilitados por
> padrão** e cria dois usuários internos automaticamente — `admin` (usado pelo próprio
> operator para orquestrar rebalances) e `healthcheck` (usado só para o readiness probe).
> Você não vai precisar mexer nisso diretamente (tudo acontece via `KafkaRebalance`), mas
> vale saber que a API não fica aberta sem autenticação — diferente de muitos tutoriais do
> Cruise Control "puro" (não-Strimzi, como o que a [Axual explica em detalhe](https://axual.com/blog/apache-kafka-cruise-control))
> que às vezes rodam a API sem proteção nenhuma numa demo.

## 8. Goals: Visão Geral (Hard vs Soft)

Ainda sem executar nada — só para você já sair deste Day sabendo *como o Cruise Control
pensa* antes de ver isso em ação no Day 7. Cada proposta de otimização é calculada contra
uma lista ordenada de **goals** (metas). A ordem importa: o Analyzer processa a lista de
cima para baixo, priorizando os primeiros goals quando dois goals entram em conflito. Cada
goal se classifica em uma de duas categorias, **fixas no código do Cruise Control** (você
não pode reclassificar um goal de hard para soft):

- **Hard goals** — o Analyzer **precisa incluir** esses goals na execução da proposta. Se um
  hard goal não puder ser satisfeito, a proposta inteira falha (a menos que você use
  `skipHardGoalCheck: true` — ver Day 7, e entenda o risco antes de usar).
- **Soft goals** — otimizados na melhor medida do possível, mas não bloqueiam a proposta se
  não forem 100% satisfeitos.

Um subconjunto comum de goals, na ordem de prioridade que o Cruise Control usa por padrão:

| Goal | Hard/Soft | O que faz |
|---|---|---|
| `RackAwareGoal` | Hard | Garante que réplicas de uma partição fiquem em racks/zonas diferentes |
| `ReplicaCapacityGoal` | Hard | Nenhum broker recebe mais réplicas do que o limite configurado |
| `DiskCapacityGoal` | Hard | Nenhum broker ultrapassa a capacidade de disco (80% por padrão — ver Day 7) |
| `NetworkInboundCapacityGoal` / `NetworkOutboundCapacityGoal` | Hard | Nenhum broker ultrapassa a capacidade de rede configurada |
| `CpuCapacityGoal` | Hard | Nenhum broker ultrapassa a capacidade de CPU configurada |
| `ReplicaDistributionGoal` | Soft | Distribui o **número** de réplicas igualmente entre brokers |
| `DiskUsageDistributionGoal` | Soft | Distribui os **bytes em disco** igualmente entre brokers |
| `NetworkInboundUsageDistributionGoal` / `NetworkOutboundUsageDistributionGoal` | Soft | Distribui o uso de rede igualmente |
| `CpuUsageDistributionGoal` | Soft | Distribui o uso de CPU igualmente |
| `TopicReplicaDistributionGoal` | Soft | Distribui réplicas de **cada tópico** igualmente entre brokers (não só o total) |
| `LeaderReplicaDistributionGoal` | Soft | Distribui a **liderança** de partições igualmente (quem lidera = quem sofre a carga de I/O de fato) |

> **Pegadinha real de produção — fica de gancho pro Day 7:** "hard goal" **não** significa
> "goal que precisa ser satisfeito". Significa "goal que precisa ser **executado**" durante o
> cálculo da proposta. É um mal-entendido documentado até pela própria comunidade Strimzi
> (várias pessoas configuram só `RackAwareGoal` como hard goal e se surpreendem quando a
> proposta falha por `NetworkInboundCapacityGoal` mesmo sem declará-lo). O motivo, os
> `default.goals`/`hard.goals`/`self.healing.goals`, e um caso real onde isso derrubou uma
> proposta inteira por causa da capacidade de rede default (10MB/s) ser baixa demais para o
> tráfego real, vão com detalhe completo no
> [Day 7](../Day7-CruiseControl-Avancado/#8-catálogo-completo-de-goals-hard-vs-soft).

Omitir `spec.goals` no `KafkaRebalance` usa o `cruiseControl.config.default.goals` do
cluster (que por padrão inclui uma lista maior — ver Day 7). Uma boa palestra pra
complementar essa visão geral com o ponto de vista de quem mantém o projeto é a
[introdução ao Cruise Control no Kafka Summit London 2023](https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/).

## 9. Cleanup

```bash
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # devem sumir sozinhas por causa do deleteClaim: true
kind delete cluster --name strimzi-day6
```

> Como este Day não cria nenhum `KafkaTopic` nem `KafkaRebalance`, a ordem de deleção não
> tem a armadilha de finalizer travado que existe quando há tópicos envolvidos (ver
> [Day 7](../Day7-CruiseControl-Avancado/) para essa ressalva, relevante a partir do
> momento em que você começa a criar tópicos de verdade).

## 10. E Agora? O Que Vem no Day 7

Este Day cobriu a apresentação: o que o Cruise Control é, por que ele existe, como ele
pensa (goals) e como confirmar que ele está de pé no seu cluster. Colocar a mão de verdade
é o **[Day 7 — Cruise Control Avançado](../Day7-CruiseControl-Avancado/)**, que cobre —
tudo com comandos reais, testados de ponta a ponta:

- Uma **carga de trabalho realista multi-tópico** para ter algo de fato pra rebalancear.
- Os três modos manuais de `KafkaRebalance` — **`full`** (proposta → aprovação →
  execução), **`add-brokers`** (escalar com segurança) e **`remove-brokers`** (reduzir sem
  o Strimzi recusar o scale-down, como quase aconteceu no Day 3).
- **Self-healing** de falha de broker (e a ressalva sobre `kubectl delete pod` vs. falha
  real).
- O **catálogo completo** de goals e a pegadinha real do `hard.goals`.
- **Capacity planning** de verdade: `brokerCapacity`, overrides por broker, e dois bugs
  documentados que derrubam propostas silenciosamente (CPU default de 1 core, e rede
  default baixa demais).
- **Goals customizados por incidente**, **rebalanceamento intra-broker (JBOD)**, **tuning
  de performance/throttling**, os **5 tipos de self-healing**, `autoRebalance`, segurança
  da API REST, e uma seção honesta sobre os **limites arquiteturais** do Cruise Control.
- Um **cenário de incidente completo**, simulando disco cheio em produção do início ao fim.

## 11. Referências

| Recurso | URL |
|---|---|
| Strimzi — Cruise Control for cluster rebalancing (deploy) | https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str |
| Strimzi — Blog: Cruise Control (introdução original, 2020) | https://strimzi.io/blog/2020/06/15/cruise-control/ |
| Red Hat — Streams for Apache Kafka (KRaft): conceitos de Cruise Control | https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str |
| Axual — Apache Kafka Cruise Control (visão prática) | https://axual.com/blog/apache-kafka-cruise-control |
| Confluent — Kafka Summit London 2023: An Introduction to Kafka Cruise Control | https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/ |
| Cruise Control — repositório (fork ativo, pós-LinkedIn) | https://github.com/cruise-control-for-kafka/cruise-control |
| Strimzi — KafkaRebalance API Reference | https://strimzi.io/docs/operators/latest/configuring#type-KafkaRebalance-reference |
| kind | https://kind.sigs.k8s.io/ |
| Release usada neste lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Parte da série **Espetinho de Kafka** — Strimzi Day 6: Cruise Control (Introdução).
> Day anterior: [Kafka Access Operator](../Day5-KafkaAccessOperator/).
> Próximo Day: [Cruise Control Avançado](../Day7-CruiseControl-Avancado/).
