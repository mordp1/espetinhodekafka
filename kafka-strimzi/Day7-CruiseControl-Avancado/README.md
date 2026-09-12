# Cruise Control Avançado — Rebalanceamento na Prática, Goals, Capacity Planning, JBOD e Automação Total

> **Objetivo:** sair da teoria do [Day 6](../Day6-CruiseControl/) — o que o Cruise Control é
> e como ele pensa — e **colocar a mão de verdade**: gerar uma carga realista, pedir uma
> proposta de rebalanceamento, aprovar e executar, escalar e reduzir o cluster com
> segurança, e então ir além do fluxo básico até o que separa "eu rodei um
> `KafkaRebalance` uma vez" de "eu confio o suficiente no Cruise Control para deixá-lo
> tomar decisões sozinho em produção": o catálogo completo de goals e suas pegadinhas,
> capacity planning real, rebalanceamento intra-broker em JBOD, tuning de performance, os
> cinco tipos de self-healing, automação total via `autoRebalance`, segurança da API e —
> igualmente importante — os limites arquiteturais que o Cruise Control **não** resolve.
> Todo comando deste Day foi executado de ponta a ponta (incluindo um `kind delete
> cluster` seguido de uma repetição completa do zero) antes de ser documentado aqui —
> as ressalvas marcadas como "reproduzido neste lab" são bugs reais que apareceram durante
> esse teste, não hipóteses.

---

## Índice

1. [Contexto](#1-contexto)
2. [Pré-requisitos](#2-pré-requisitos)
3. [Estrutura do Lab](#3-estrutura-do-lab)
4. [Subindo o Cluster Kind](#4-subindo-o-cluster-kind)
5. [Instalando o Strimzi Cluster Operator](#5-instalando-o-strimzi-cluster-operator)
6. [Deploy: Kafka + Node Pools JBOD + Cruise Control Avançado](#6-deploy-kafka--node-pools-jbod--cruise-control-avançado)
7. [Modelando uma Carga Realista (Multi-Tópico)](#7-modelando-uma-carga-realista-multi-tópico)
8. [Rebalance Completo: Proposta, Aprovação, Execução](#8-rebalance-completo-proposta-aprovação-execução)
9. [Escalando com Segurança: `add-brokers`](#9-escalando-com-segurança-add-brokers)
10. [Removendo com Segurança: `remove-brokers`](#10-removendo-com-segurança-remove-brokers)
11. [Catálogo Completo de Goals (Hard vs Soft)](#11-catálogo-completo-de-goals-hard-vs-soft)
12. [Capacity Planning: `brokerCapacity` e os Bugs de "1 Core" e Rede](#12-capacity-planning-brokercapacity-e-os-bugs-de-1-core-e-rede)
13. [Goals Customizados por Incidente](#13-goals-customizados-por-incidente)
14. [Rebalanceamento Intra-Broker (JBOD)](#14-rebalanceamento-intra-broker-jbod)
15. [Tuning de Performance: Concorrência e Throttling](#15-tuning-de-performance-concorrência-e-throttling)
16. [Self-Healing Completo: os 5 Tipos de Anomalia](#16-self-healing-completo-os-5-tipos-de-anomalia)
17. [Automação Total: `autoRebalance`](#17-automação-total-autorebalance)
18. [Segurança da API REST do Cruise Control](#18-segurança-da-api-rest-do-cruise-control)
19. [Problemas Conhecidos em Produção](#19-problemas-conhecidos-em-produção)
20. [Limites Arquiteturais do Cruise Control](#20-limites-arquiteturais-do-cruise-control)
21. [Cenário Completo: Disco Cheio às 3h da Manhã](#21-cenário-completo-disco-cheio-às-3h-da-manhã)
22. [Cleanup](#22-cleanup)
23. [Referências](#23-referências)

---

## 1. Contexto

O [Day 6](../Day6-CruiseControl/) apresentou o Cruise Control — o que ele é, os quatro
componentes internos (Load Monitor, Analyzer, Anomaly Detector, Executor), e como o Strimzi
o integra como Custom Resource — mas ficou só na introdução, sem gerar carga nem executar
nenhum `KafkaRebalance`. Este Day é onde a teoria vira prática, e onde a prática vira
profundidade: começamos pelo fluxo operacional básico (carga de trabalho real, os três
modos manuais de `KafkaRebalance` — `full`, `add-brokers`, `remove-brokers` — e
self-healing de falha de broker) e seguimos até as perguntas que separam quem "usou Cruise
Control uma vez" de quem realmente entende a ferramenta:

- Por que uma proposta com só `RackAwareGoal` como hard goal falhou por causa de
  `NetworkInboundCapacityGoal`, que nem foi declarado?
- Por que o `CpuCapacityGoal` às vezes recomenda "adicionar 3 brokers" num cluster que mal
  está sendo usado?
- Como você resolve **um disco cheio dentro de um único broker** — não entre brokers, mas
  entre os discos JBOD do mesmo broker?
- Como você evita que um rebalance "trave" por horas por causa de um parâmetro que parecia
  inofensivo?
- Quantos tipos de falha o self-healing realmente cobre além de "broker caiu"?
- Dá pra remover o passo manual de aprovar um `KafkaRebalance` toda vez que você escala o
  cluster?
- E, com honestidade técnica: **o que o Cruise Control não resolve**, mesmo bem configurado?

Este Day responde todas — com um cluster próprio (JBOD, capacity planning configurado,
self-healing mais completo) e uma carga de trabalho multi-tópico desenhada especificamente
pra criar desbalanceamento real e heterogêneo.

## 2. Pré-requisitos

- Ter feito o [Day 6](../Day6-CruiseControl/) (o que é Cruise Control, arquitetura,
  visão geral de goals) e o [Day 2](../Day2-NodePools/)/[Day 3](../Day3-NodePools-Avancado/)
  (`KafkaNodePool` básico e avançado) — este Day assume que você já entende o problema que
  o Cruise Control resolve, só não colocou a mão nele ainda.
- [Docker](https://docs.docker.com/get-docker/) com pelo menos ~7GB de RAM livres (o
  storage JBOD deste Day usa duas PVCs por broker em vez de uma)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)

> **Nota de recursos, observada testando este Day de ponta a ponta:** com várias
> operações pesadas em sequência (carga multi-tópico, JBOD, rebalances) rodando por horas
> num laptop, o próprio `strimzi-cluster-operator` pode entrar em crash-loop por perder a
> eleição de líder sob pressão de CPU (`Stopped being a leader => exiting` no log) — ele se
> recupera sozinho (Kubernetes reinicia o pod, e ele retoma a reconciliação de onde parou),
> mas isso deixa `KafkaRebalance` parados por mais tempo do que o normal. Se algo parecer
> "travado" por muito tempo, confira `kubectl get pods -n kafka -l
> name=strimzi-cluster-operator` antes de assumir que é um bug do YAML.

## 3. Estrutura do Lab

```
Day7-CruiseControl-Avancado/
├── kind-config.yaml                       # cluster kind: 1 control-plane + 3 workers
├── kafka-nodepool-controller.yaml         # KafkaNodePool "controller" (3 réplicas)
├── kafka-nodepool-broker.yaml             # KafkaNodePool "broker" — JBOD, 2 volumes/broker
├── kafka-cluster.yaml                     # Kafka CR: brokerCapacity + self-healing completo + autoRebalance
├── kafka-topic-heavy.yaml                 # KafkaTopic "shop.events"
├── kafka-topics-workload.yaml             # 6 KafkaTopics adicionais — carga realista (seção 7)
├── kafkarebalance-full.yaml               # KafkaRebalance mode=full
├── kafkarebalance-add-brokers.yaml        # KafkaRebalance mode=add-brokers
├── kafkarebalance-remove-brokers.yaml     # KafkaRebalance mode=remove-brokers
├── kafkarebalance-disk-incident.yaml      # goals customizados + skipHardGoalCheck + excludedTopics
├── kafkarebalance-intra-broker.yaml       # mode=full, rebalanceDisk=true
├── kafkarebalance-remove-disks.yaml       # mode=remove-disks
├── kafkarebalance-throttled.yaml          # concorrência/throttle explícitos e seguros
├── kafkarebalance-autoscale-templates.yaml# templates usados por autoRebalance
├── README.md
└── README-EN.md
```

## 4. Subindo o Cluster Kind

```bash
kind create cluster --config=kind-config.yaml --name strimzi-day7
kubectl get nodes -o wide
```

## 5. Instalando o Strimzi Cluster Operator

```bash
kubectl create namespace kafka

curl -L https://github.com/strimzi/strimzi-kafka-operator/releases/download/1.1.0/strimzi-cluster-operator-1.1.0.yaml \
  | sed 's/namespace: myproject/namespace: kafka/g' \
  | kubectl create -f - -n kafka

kubectl wait deployment/strimzi-cluster-operator -n kafka --for=condition=Available --timeout=180s
```

## 6. Deploy: Kafka + Node Pools JBOD + Cruise Control Avançado

Duas diferenças em relação ao Day 6 já na topologia: [`kafka-nodepool-broker.yaml`](kafka-nodepool-broker.yaml)
agora tem **dois volumes JBOD** por broker (pré-requisito para a seção 14), e
[`kafka-cluster.yaml`](kafka-cluster.yaml) configura `brokerCapacity`, três tipos de
self-healing e `autoRebalance`:

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

> **Por que `inboundNetwork`/`outboundNetwork` não ficaram no default (10000KiB/s):**
> reproduzimos, testando este lab do zero, uma proposta de `full-rebalance` (seção 8)
> falhando permanentemente com `NetworkInboundCapacityGoal` porque o burst de carga da
> seção 7 excede o default de ~10MB/s por broker — mesmo num cluster kind local. Detalhe
> completo na seção 12.

> **Por que `autoRebalance` não entra ainda:** ele só é habilitado na seção 17, de
> propósito. Reproduzimos ao vivo o que acontece se ele já estiver ligado desde este
> deploy inicial: no primeiro `kubectl scale kafkanodepool broker --replicas=4` (seção 9),
> o Cluster Operator dispara o `add-brokers` sozinho, automaticamente — e a demonstração
> manual de `add-brokers`/`remove-brokers` das seções 9 e 10 nunca chega a acontecer do
> jeito documentado, porque o operator já resolveu tudo antes de você aplicar o
> `KafkaRebalance` manual. Fazer o fluxo manual primeiro, e só depois automatizar, é
> deliberado — é assim que você entende o que está sendo automatizado antes de confiar
> nisso de olhos fechados.

```bash
kubectl apply -f kafka-nodepool-controller.yaml -n kafka
kubectl apply -f kafka-nodepool-broker.yaml -n kafka
kubectl apply -f kafka-cluster.yaml -n kafka

kubectl wait kafka/my-cluster --for=condition=Ready --timeout=300s -n kafka
kubectl get pods -n kafka
kubectl get kafkanodepool broker -n kafka -o jsonpath='{.status.nodeIds}'; echo
```

Anote os `nodeIds` reais do node pool `broker` — vamos usá-los nas seções 9, 12 e 14
(o override de `brokerCapacity` e o `moveReplicasOffVolumes` assumem o broker `0`, que é o
esperado neste lab: o node pool `controller` fica com os IDs mais altos, `[3,4,5]`, e
`broker` com os mais baixos, `[0,1,2]` — mas **confirme os NODEIDS reais**, usar um ID de
`controller` num campo que espera um broker falha com `IllegalArgumentException: Some/all
brokers specified don't exist`, reproduzido neste lab).

## 7. Modelando uma Carga Realista (Multi-Tópico)

Sem dados de verdade e sem heterogeneidade entre tópicos, qualquer rebalance é irrelevante —
todos os brokers começam "vazios" e igualmente balanceados, e a proposta do Cruise Control
vira um exercício de fé ("confia que funciona"). Para realmente ver o Analyzer trabalhando,
precisamos de um cluster com **desbalanceamento real e heterogêneo** — exatamente como um
cluster de produção que atende vários domínios de negócio ao mesmo tempo.

O [`kafka-topic-heavy.yaml`](kafka-topic-heavy.yaml) (tópico `shop.events`, 12 partições,
RF 3) já existia neste Day. Adicionamos em
[`kafka-topics-workload.yaml`](kafka-topics-workload.yaml) mais **6 tópicos** desenhados de
propósito para criar tipos diferentes de desbalanceamento — não é só "mais dado", é
desbalanceamento **por causas diferentes**, o que é o cenário real que você vai encontrar em
produção:

| Tópico | Partições | RF | Perfil | Por que está aqui |
|---|---|---|---|---|
| `shop.events` | 12 | 3 | Geral / baseline | Eventos de navegação/carrinho |
| `clickstream.raw` | 24 | 3 | 🔥 **Quente** | Mais partições + maior throughput de todos — domina disco e rede em quem hospedar as réplicas dele |
| `orders.created` | 6 | 3 | Compactado | `cleanup.policy=compact` — disco **não** cresce linear com throughput; contraste direto com os tópicos append-only |
| `payments.processed` | 6 | 3 | Crítico, volume baixo | `min.insync.replicas=3` — protegido com mais rigor, mas pouco volume de propósito (base para `excludedTopics` na seção 13) |
| `inventory.updates` | 8 | 2 | RF heterogêneo | RF 2 (vs RF 3 nos demais) — o Cruise Control lida bem com RF misto no mesmo cluster |
| `audit.logs` | 4 | 3 | Pesado por **retenção** | Poucas partições, mensagens grandes, 30 dias de retenção — fica pesado sem ter throughput alto |
| `notifications.push` | 6 | 3 | ❄️ **Frio** | Quase ocioso — baseline para contraste com `clickstream.raw` |

Aplique os tópicos e gere carga real com o `kafka-producer-perf-test.sh` embutido na imagem
do Kafka (ajuste `--num-records` para baixo se seu laptop estiver sofrendo — o importante é
a **proporção** entre tópicos, não o volume absoluto):

```bash
kubectl apply -f kafka-topic-heavy.yaml -n kafka
kubectl apply -f kafka-topics-workload.yaml -n kafka

# shop.events — baseline (~500MB brutos)
kubectl -n kafka run kafka-producer-shop -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic shop.events --num-records 500000 --record-size 1000 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# clickstream.raw — o tópico quente (~1,2GB brutos, throughput máximo)
kubectl -n kafka run kafka-producer-clickstream -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic clickstream.raw --num-records 3000000 --record-size 400 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# orders.created — volume moderado, tópico compactado
# ATENÇÃO: kafka-producer-perf-test.sh não tem opção de chave, e tópico compactado
# REJEITA mensagem sem chave (InvalidRecordException — reproduzido neste lab). Por isso
# usamos aqui o kafka-console-producer.sh com parse.key=true, gerando
# "order-<id>:<payload>" via awk.
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

# payments.processed — volume baixo de propósito
kubectl -n kafka run kafka-producer-payments -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic payments.processed --num-records 80000 --record-size 400 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# inventory.updates — RF2
kubectl -n kafka run kafka-producer-inventory -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic inventory.updates --num-records 200000 --record-size 300 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# audit.logs — mensagens grandes, poucos registros, retenção longa
kubectl -n kafka run kafka-producer-audit -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic audit.logs --num-records 40000 --record-size 3000 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092

# notifications.push — quase ocioso
kubectl -n kafka run kafka-producer-notifications -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-producer-perf-test.sh \
  --topic notifications.push --num-records 5000 --record-size 200 --throughput -1 \
  --producer-props bootstrap.servers=my-cluster-kafka-bootstrap:9092
```

Ao todo isso é **66 partições** e ~1,9GB brutos antes de replicação. Confira a distribuição
atual antes de seguir para a seção 8 — é o "antes" que vai te permitir enxergar o "depois":

```bash
kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
  --bootstrap-server my-cluster-kafka-bootstrap:9092
```

> **Espere alguns minutos antes de pedir qualquer proposta.** O Cruise Control precisa
> acumular pelo menos uma janela de amostragem de métricas (por padrão, 5 minutos no
> Strimzi) depois que essa carga termina de ser gerada. Pedir uma proposta cedo demais é a
> causa mais comum de `NotEnoughValidWindows` — ver seção 8.

## 8. Rebalance Completo: Proposta, Aprovação, Execução

O `KafkaRebalance` funciona em duas etapas separadas por design — o operator **nunca** move
dados sem uma aprovação explícita, a não ser que você opte por auto-aprovação (seção 17):

```bash
kubectl apply -f kafkarebalance-full.yaml -n kafka
kubectl get kafkarebalance -n kafka -w
```

O `status.conditions` do objeto evolui assim:

```
PendingProposal  →  ProposalReady  →  (aprovar)  →  Rebalancing  →  Ready
```

> **Ressalva importante:** o Cruise Control precisa acumular **janelas de amostragem de
> métricas** antes de conseguir montar um modelo de carga confiável (por padrão, várias
> janelas de alguns minutos cada no upstream — o Strimzi reduz o tamanho da janela para 5
> minutos). Se você aplicar o `KafkaRebalance` logo depois do cluster ficar `Ready` — ou
> logo depois de gerar a carga da seção 7 — é bem provável que o `status` volte com uma
> condição de erro do tipo `NotEnoughValidWindows`. Isso não é um bug — é o Cruise Control
> recusando dar uma proposta baseada em dado insuficiente (o mesmo tipo de cautela que você
> quer numa ferramenta que move partições de produção). Espere alguns minutos e force uma
> nova tentativa:
>
> ```bash
> kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=refresh -n kafka --overwrite
> ```

Quando o status virar `ProposalReady`, inspecione o resumo da proposta antes de aprovar —
isso é o que você mostraria num PR de infra antes de rodar em produção:

```bash
kubectl describe kafkarebalance full-rebalance -n kafka
```

O `status` traz um resumo (`Optimization Result`) com bytes movidos, número de réplicas
realocadas, e mudança estimada por goal. Com a carga multi-tópico da seção 7, espere ver o
`clickstream.raw` dominando o volume de bytes movidos — é exatamente o comportamento
esperado do `DiskUsageDistributionGoal`/`NetworkInboundUsageDistributionGoal` tentando
corrigir o tópico mais pesado do cluster. Aprovando:

```bash
kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance full-rebalance -n kafka -w
```

Quando o status voltar para `Ready`, o rebalanceamento terminou — sem downtime, sem você
ter calculado reassignment na mão. Rode o `kafka-topics.sh --describe` da seção 7 de novo e
compare a distribuição antes/depois.

> **Vale calibrar a expectativa:** com RF 3 (ou RF 2 no caso de `inventory.updates`) em
> exatamente 3 brokers, boa parte das réplicas já existe em todo broker por construção — o
> desbalanceamento de disco visível é menor do que se imagina antes de rodar. O que este
> `full-rebalance` tende a corrigir de forma mais visível é a **distribuição de liderança**
> (`LeaderReplicaDistributionGoal`), não necessariamente um grande volume de bytes movidos.
> O desbalanceamento *dramático* de verdade aparece na seção 9, quando um broker novo entra
> genuinamente vazio.

## 9. Escalando com Segurança: `add-brokers`

Escala o pool de brokers de 3 para 4, exatamente como no [Day 2](../Day2-NodePools/):

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka
kubectl get kafkanodepool broker -n kafka
```

Confirme o `nodeId` do broker novo na coluna `NODEIDS` (deve ser `6`, seguindo a mesma
numeração sequencial observada no Day 2 — mas **confirme o valor real** antes do próximo
passo). Se for diferente de `6`, ajuste `kafkarebalance-add-brokers.yaml`.

Sem o Cruise Control, esse broker novo ficaria **vazio** para sempre — nada força o Kafka a
mover réplicas existentes para ele. O `mode: add-brokers` resolve isso: pede ao Cruise
Control para mover uma fração das réplicas existentes especificamente para os brokers
listados. Com 66 partições espalhadas em 7 tópicos heterogêneos (seção 7), esse é um cenário
bem mais realista que "cluster vazio ganhando um broker" — o Cruise Control precisa decidir
*quais* réplicas de *quais* tópicos migrar para não recriar o desbalanceamento em outro
lugar.

```bash
kubectl apply -f kafkarebalance-add-brokers.yaml -n kafka
kubectl annotate kafkarebalance add-brokers-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance add-brokers-rebalance -n kafka -w
```

> **Pegadinha reproduzida neste lab:** se você aplicar o `add-brokers-rebalance` logo
> depois do pod do broker novo ficar `Ready` (sem esperar o Cruise Control absorver o
> broker novo em pelo menos uma janela de amostragem — na prática, uns 5 minutos), o
> `status` volta `NotReady` com uma `NullPointerException` genérica (`Cannot invoke
> "BrokerCapacityInfo.capacity()"...`) — o `capacity.json` interno já lista o broker
> novo corretamente (o Strimzi deriva a capacidade dele na hora), mas o modelo de carga
> do Cruise Control ainda não o incluiu. Isso **não é um erro fatal**: forçar uma nova
> tentativa resolve, do mesmo jeito que no `NotEnoughValidWindows` da seção 8:
> ```bash
> kubectl annotate kafkarebalance add-brokers-rebalance strimzi.io/rebalance=refresh -n kafka --overwrite
> ```

Depois de `Ready`, confira que o broker novo já tem réplicas de fato:

```bash
kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
  --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
  --bootstrap-server my-cluster-kafka-bootstrap:9092
```

## 10. Removendo com Segurança: `remove-brokers`

Aqui está o contraste direto com o [Day 3](../Day3-NodePools-Avancado/): lá, tentamos
remover manualmente um node com réplicas atribuídas e o Strimzi **reverteu** o scale-down
sozinho, como rede de segurança. O `mode: remove-brokers` do Cruise Control automatiza
exatamente o passo que faltava — esvaziar o broker **antes** de você reduzir o
`replicas`:

```bash
kubectl apply -f kafkarebalance-remove-brokers.yaml -n kafka
kubectl annotate kafkarebalance remove-brokers-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
kubectl get kafkarebalance remove-brokers-rebalance -n kafka -w
```

Só depois do `status` virar `Ready` (ou seja, depois que o broker `6` não tem mais nenhuma
réplica atribuída) é seguro reduzir o node pool:

```bash
kubectl scale kafkanodepool broker --replicas=3 -n kafka
```

Diferente da tentativa manual do Day 3, aqui **não há chance de o Strimzi reverter o
scale-down** — o Cruise Control já garantiu que a condição que causava a rejeição
(réplicas atribuídas ao node) não existe mais antes de você sequer tocar no `replicas`.

## 11. Catálogo Completo de Goals (Hard vs Soft)

O Day 6 mostrou um subconjunto comum de goals (o mesmo usado em
[`kafkarebalance-full.yaml`](kafkarebalance-full.yaml), seção 8). Esta é a lista completa
dos `default.goals` do Cruise Control, na ordem de prioridade real (o Analyzer processa de
cima para baixo):

| # | Goal | Categoria | O que faz |
|---|---|---|---|
| 1 | `RackAwareGoal` | Hard | Réplicas de uma partição em racks/zonas diferentes |
| 2 | `MinTopicLeadersPerBrokerGoal` | Hard | Garante um mínimo de líderes por broker para tópicos configurados |
| 3 | `ReplicaCapacityGoal` | Hard | Limite máximo de réplicas por broker |
| 4 | `DiskCapacityGoal` | Hard | Nenhum broker ultrapassa o **threshold** de disco (80% da capacidade — não 100%, ver abaixo) |
| 5 | `NetworkInboundCapacityGoal` | Hard | Nenhum broker ultrapassa o threshold de rede de entrada (80%) |
| 6 | `NetworkOutboundCapacityGoal` | Hard | Nenhum broker ultrapassa o threshold de rede de saída (80%) |
| 7 | `CpuCapacityGoal` | Hard | Nenhum broker ultrapassa o threshold de CPU (**70%**, o mais agressivo de todos) |
| 8 | `ReplicaDistributionGoal` | Soft | Distribui a contagem de réplicas entre brokers |
| 9 | `PotentialNwOutGoal` | Soft | Evita que uma falha de broker sobrecarregue a rede dos demais ao reatribuir a liderança |
| 10 | `DiskUsageDistributionGoal` | Soft | Distribui bytes em disco entre brokers |
| 11 | `NetworkInboundUsageDistributionGoal` | Soft | Distribui uso de rede de entrada |
| 12 | `NetworkOutboundUsageDistributionGoal` | Soft | Distribui uso de rede de saída |
| 13 | `CpuUsageDistributionGoal` | Soft | Distribui uso de CPU |
| 14 | `TopicReplicaDistributionGoal` | Soft | Distribui réplicas **por tópico** (não só o agregado) |
| 15 | `LeaderReplicaDistributionGoal` | Soft | Distribui liderança de partições |
| 16 | `LeaderBytesInDistributionGoal` | Soft | Distribui o bytes-in que cada broker recebe **como líder** |

Fora dessa lista padrão existem os goals de rebalanceamento intra-broker
(`IntraBrokerDiskCapacityGoal`, `IntraBrokerDiskUsageDistributionGoal` — seção 14) e o
legado `KafkaAssignerDiskUsageDistributionGoal`, que não entram no `default.goals`.

**Os thresholds importam mais do que parecem:** um goal "de capacidade" não dispara em
100% de uso — dispara em `disk.capacity.threshold` (0.8), `cpu.capacity.threshold` (0.7) ou
`network.{inbound,outbound}.capacity.threshold` (0.8). Ou seja: um broker com **71% de
CPU** já é, tecnicamente, uma violação de `CpuCapacityGoal`. Isso é intencional (você quer
folga antes de bater no limite real), mas surpreende gente lendo `kubectl describe
kafkarebalance` pela primeira vez e vendo "capacity goal violated" num broker que "não
parece tão cheio assim".

### A hierarquia de goals que ninguém lê até ser mordido por ela

```
hard.goals          ⊆  default.goals   ⊆  goals (todos disponíveis no classpath)
hard.goals          ⊆  self.healing.goals
anomaly.detection.goals  (subconjunto de self.healing.goals — define o que conta como "goal violation")
```

- `default.goals` — usado quando um `KafkaRebalance` **não** declara `spec.goals`.
- `hard.goals` — os goals que **toda** proposta precisa executar, custom ou não.
- `self.healing.goals` — usado quando o Anomaly Detector dispara self-healing automático
  (precisa ser superset de `hard.goals`, senão o self-healing simplesmente não consegue
  corrigir a anomalia).
- `anomaly.detection.goals` — define quais violações de goal contam como "anomalia" pro
  self-healing de goal violation (seção 16) reagir.

> **A pegadinha real de produção:** "hard goal" **não significa** "goal que precisa ser
> satisfeito" — significa "goal que precisa ser **executado**" durante o cálculo da
> proposta. É um mal-entendido documentado até na comunidade Strimzi: alguém configurou
> só `RackAwareGoal` como hard goal, esperando que só ele fosse obrigatório, e a proposta
> falhou com `"Insufficient capacity for networkInbound"` — um goal que a pessoa nunca
> tinha declarado como hard. A explicação de um mantenedor foi direta: *"the `hard.goals`
> config is NOT a list of goals 'that must be satisfied' but rather a list of goals 'that
> must be executed'"* — `NetworkInboundCapacityGoal` é hard-coded como mandatório no
> Cruise Control upstream, independente do que você configura como `hard.goals` no
> cluster. A forma correta de "desligar" um goal capacity de verdade é **excluí-lo de
> `default.goals`** no cluster, não tentar rebaixá-lo para soft (não dá, a classificação é
> fixa no código). É exatamente essa mecânica que o `skipHardGoalCheck` da seção 13 usa
> para contornar. Reproduzimos essa mesma pegadinha na prática neste lab — ver seção 12.
> ([discussão original](https://github.com/orgs/strimzi/discussions/9546))

## 12. Capacity Planning: `brokerCapacity` e os Bugs de "1 Core" e Rede

O `Kafka.spec.cruiseControl.brokerCapacity` diz ao Cruise Control quanto de CPU/rede cada
broker tem disponível — é contra esse número que `CpuCapacityGoal`,
`NetworkInboundCapacityGoal` e `NetworkOutboundCapacityGoal` calculam violação. Repare que
**não existe campo de disco** aqui: capacidade de disco o Strimzi deriva automaticamente do
tamanho configurado nos volumes do `KafkaNodePool` — diferente do Cruise Control "puro",
que exige um `capacityJBOD.json` mantido manualmente.

```yaml
brokerCapacity:
  cpu: "2"                    # cores ou millicores: "1", "1.500", "1500m"
  inboundNetwork: 200000KiB/s
  outboundNetwork: 200000KiB/s
  overrides:
    - brokers: [0]              # override por broker — útil com hardware heterogêneo
      cpu: "4"
      inboundNetwork: 400000KiB/s
      outboundNetwork: 400000KiB/s
```

> **O bug de produção que mais confunde gente nova em Cruise Control:** se você **não**
> configura `brokerCapacity.cpu`, o Cruise Control assume **1 core por broker** — não
> importa quantos cores o node realmente tem. Um caso real reportado na comunidade Strimzi
> mostrava um cluster de 6 brokers, cada um efetivamente usando bem mais que 1 core, com o
> Cruise Control reportando `CORE_NUM: 1` para todos: 6 brokers × 1 core = 6 cores de
> capacidade "teórica" contra ~859% de utilização somada — o `CpuCapacityGoal` concluiu, de
> forma totalmente equivocada, que era preciso **adicionar pelo menos 3 brokers**. O
> problema não era falta de capacidade real; era o Cruise Control enxergando 1/8 (ou
> menos) da CPU que o broker realmente tinha. **Configure `brokerCapacity.cpu` sempre que
> seus brokers tiverem mais de 1 core** — o que, na prática, é sempre.
> ([issue original](https://github.com/strimzi/strimzi-kafka-operator/issues/5951))

> **O mesmo tipo de bug existe para rede, e é fácil de perder de vista porque ninguém
> escreve sobre ele com o mesmo destaque do "1 core":** o default de
> `inboundNetwork`/`outboundNetwork` é **10000KiB/s (~10MB/s) por broker** — um número que
> já era baixo pra hardware real em 2015, e é trivialmente ultrapassado por qualquer burst
> de produtor de teste, mesmo num cluster kind local rodando na loopback do Docker.
> Reproduzimos isso de forma determinística testando este Day do zero: com o default de
> 10MB/s, a carga da seção 7 **derruba permanentemente** a proposta do `full-rebalance` da
> seção 8 com `OptimizationFailureException: [NetworkInboundCapacityGoal] Insufficient
> capacity for networkInbound` — e como `NetworkInboundCapacityGoal` está na lista de
> `spec.goals` do `kafkarebalance-full.yaml` (e é hard-coded como mandatório de qualquer
> forma, pela mesma pegadinha da seção 11), a proposta falha até a janela "suja" expirar do
> modelo — o que pode levar mais de 1 hora dependendo de `num.broker.metrics.windows`.
> Configurar `brokerCapacity.inboundNetwork`/`outboundNetwork` com um valor realista (como
> os 200000KiB/s deste `kafka-cluster.yaml`) evita o problema por completo. Trate isso como
> parte do mesmo capacity planning que você já faz para CPU — não é overhead extra, é o
> mesmo cuidado, num campo diferente.

## 13. Goals Customizados por Incidente

Cada `KafkaRebalance` pode ter seu próprio `spec.goals`, diferente do `default.goals` do
cluster — útil quando você quer resolver **um problema específico**, rápido, sem pagar o
custo (em tempo e em I/O) de reotimizar o cluster inteiro contra todos os goals padrão.

[`kafkarebalance-disk-incident.yaml`](kafkarebalance-disk-incident.yaml) simula exatamente
isso — disco quase cheio num broker, agora, produção:

```yaml
spec:
  mode: full
  goals:
    - DiskCapacityGoal
    - DiskUsageDistributionGoal
  skipHardGoalCheck: true
  excludedTopics: "payments\\..*"
```

Três decisões deliberadas aqui, cada uma com trade-off explícito:

- **Só dois goals, ambos de disco.** Não pedimos pro Cruise Control também rebalancear
  rede, CPU ou contagem de réplicas — queremos resolver disco e só disco, o mais rápido
  possível.
- **`skipHardGoalCheck: true`.** Lembra da seção 11: `hard.goals` do cluster precisa
  aparecer na lista de goals de **toda** proposta, a menos que você pule essa checagem
  explicitamente. Sem esse campo, esta proposta falharia por não incluir
  `NetworkInboundCapacityGoal` e os outros hard goals do cluster. Aceitamos, conscientemente,
  não verificar rack/rede/CPU **nesta execução específica** — o objetivo é apagar o
  incêndio, não fazer manutenção completa. O follow-up correto é aplicar um
  `kafkarebalance-full.yaml` (seção 8) completo depois que o incidente passar, pra
  reconciliar tudo que ficou de fora.
- **`excludedTopics: "payments\\..*"`.** Um rebalance de emergência é exatamente o tipo de
  operação que você **não** quer tocando no tópico financeiro por engano — o regex (formato
  `java.util.regex.Pattern`) garante que nenhuma réplica de `payments.processed` se mova
  aqui, não importa o que o Analyzer calcule.

```bash
kubectl apply -f kafkarebalance-disk-incident.yaml -n kafka
kubectl describe kafkarebalance disk-incident-rebalance -n kafka
# revise o Optimization Result — confirme que nenhuma réplica de payments.* aparece movida
kubectl annotate kafkarebalance disk-incident-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

## 14. Rebalanceamento Intra-Broker (JBOD)

Até aqui, todo rebalance moveu réplicas **entre brokers**. Mas o [`kafka-nodepool-broker.yaml`](kafka-nodepool-broker.yaml)
deste Day tem **dois volumes JBOD por broker** (`id: 0` e `id: 1`) — e nada garante que os
dados fiquem distribuídos igualmente entre esses dois discos *dentro* do mesmo broker. O
Cruise Control resolve isso com dois mecanismos distintos:

### `rebalanceDisk: true` — balanceamento contínuo entre discos

```yaml
# kafkarebalance-intra-broker.yaml
spec:
  mode: full
  rebalanceDisk: true
```

Liga os goals `IntraBrokerDiskCapacityGoal`/`IntraBrokerDiskUsageDistributionGoal` — move
réplicas entre os discos do **mesmo** broker para equalizar uso de disco, análogo ao que o
`DiskUsageDistributionGoal` faz entre brokers, mas um nível abaixo.

```bash
kubectl apply -f kafkarebalance-intra-broker.yaml -n kafka
kubectl annotate kafkarebalance intra-broker-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

> **Se você tomar um erro de "cluster does not have JBOD storage config" com JBOD
> configurado:** isso já foi um bug real em versões anteriores do Strimzi
> (`strimzi-kafka-operator#10280`) — a validação não reconhecia `KafkaNodePool` com storage
> JBOD corretamente configurado. Já foi corrigido, mas se você estiver numa versão mais
> antiga do operator, é a primeira coisa a checar.

### `mode: remove-disks` — esvaziar um disco antes de removê-lo fisicamente

Cenário diferente: você quer **remover um volume** (reduzir de 2 discos para 1, por
exemplo, ou trocar um disco por outro). Antes de tirar o volume do
`KafkaNodePool`, ele precisa estar vazio:

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

> **Bug reproduzido neste lab: `brokerId` precisa ser um broker de verdade.** Testamos
> primeiro com `brokerId: 3` (assumindo numeração sequencial entre os dois node pools) e a
> proposta falhou com `IllegalArgumentException: Some/all brokers specified don't exist`
> — porque neste lab o node pool `controller` fica com os IDs `[3,4,5]` e `broker` com
> `[0,1,2]`; `3` é um controller, não um broker. Confira sempre `kubectl get kafkanodepool
> broker -n kafka -o jsonpath='{.status.nodeIds}'` antes de assumir qual ID usar.

O Cruise Control move as réplicas do volume `1` do broker `0`, começando pelas **maiores** e
seguindo até as menores, para os discos remanescentes (dentro do próprio broker e nos
outros). Duas ressalvas documentadas que vale saber antes de rodar isso em produção:

- **A proposta não mostra o "antes"** — só o resultado final esperado, diferente do
  `full`/`add-brokers`/`remove-brokers`, que trazem `Optimization Result` com comparação.
- **A PVC não é apagada automaticamente.** Depois que o volume estiver logicamente vazio,
  a PVC continua existindo até você removê-la manualmente — se você esquecer, o Kafka pode
  voltar a atribuir partições novas a ela mais tarde, contradizendo a intenção de
  "esvaziei esse disco pra removê-lo".

## 15. Tuning de Performance: Concorrência e Throttling

O `Executor` do Cruise Control não move todas as réplicas da proposta de uma vez — ele
respeita limites de concorrência e throttling, configuráveis por `KafkaRebalance`:

| Campo | Default | O que controla |
|---|---|---|
| `concurrentPartitionMovementsPerBroker` | 5 | Movimentos de réplica simultâneos entrando/saindo de cada broker |
| `concurrentIntraBrokerPartitionMovements` | 2 | Movimentos simultâneos entre discos do mesmo broker (seção 14) |
| `concurrentLeaderMovements` | 1000 | Trocas de liderança simultâneas (bem mais barato que mover réplica) |
| `replicationThrottle` | sem limite | Bytes/segundo máximo usado pela movimentação de réplicas |
| `replicaMovementStrategies` | `BaseReplicaMovementStrategy` | Ordem de execução dos movimentos |

[`kafkarebalance-throttled.yaml`](kafkarebalance-throttled.yaml) configura valores
explícitos e conservadores — 10MiB/s de throttle e concorrência reduzida:

```yaml
spec:
  concurrentPartitionMovementsPerBroker: 3
  concurrentLeaderMovements: 200
  replicationThrottle: 10485760
```

> **Bug reproduzido neste lab: `replicaMovementStrategies` derruba QUALQUER rebalance.**
> Testamos originalmente com `replicaMovementStrategies` configurado (mesmo com nomes de
> classe corretos, copiados direto do Cruise Control) para ordenar a execução —
> priorizando partições sub-replicadas e réplicas maiores primeiro. Toda tentativa,
> aprovada ou não, falhava com `CruiseControlRestException: Unexpected status code 400`.
> O log do pod do Cruise Control mostrou a causa real (o `status` do `KafkaRebalance` só
> mostra o 400 genérico — mais um caso da seção 19):
> `WARN AbstractRequest:33 - Failed to parse parameters: {...} for request: /rebalance`.
> Isolamos removendo campo por campo até sobrar só `replicaMovementStrategies` — com ele
> fora, o resto (concorrência, throttle) funciona normalmente. Por segurança, este manifest
> não declara `replicaMovementStrategies`; se você quiser controlar a ordem de execução,
> teste isoladamente antes de confiar nisso num incidente real.

> **Incidente real que motiva este manifest existir:** alguém na comunidade Strimzi
> reportou um rebalance de apenas 82MB (1000 réplicas) levando **mais de uma hora**, quando
> um rebalance anterior de 80GB tinha levado 15 minutos. A causa, encontrada depois de
> investigação: `concurrentLeaderMovements`, `concurrentPartitionMovementsPerBroker` e
> `replicationThrottle` estavam todos configurados como **0**, na crença de que "0 =
> ilimitado". É o oposto — 0 significa praticamente **nenhum movimento concorrente
> permitido**. A recomendação do mantenedor foi direta: se você não tem certeza de qual
> valor usar, **omita esses campos** e deixe o Cruise Control usar os defaults, que já são
> generosos o suficiente para a maioria dos casos.
> ([discussão original](https://github.com/orgs/strimzi/discussions/7167))

```bash
kubectl apply -f kafkarebalance-throttled.yaml -n kafka
kubectl annotate kafkarebalance throttled-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
```

## 16. Self-Healing Completo: os 5 Tipos de Anomalia

O Anomaly Detector do Cruise Control reconhece **cinco** tipos de anomalia:

| Anomalia | Config | Gatilho | Ação de self-healing |
|---|---|---|---|
| **Broker failure** | `self.healing.broker.failure.enabled` | Broker registrado desaparece e não volta dentro da janela de graça | Move réplicas offline/sub-replicadas para brokers saudáveis |
| **Disk failure** | `self.healing.disk.failure.enabled` | Um disco (volume JBOD) morre com partições ficando offline | Move as réplicas daquele disco para discos saudáveis — o equivalente automático da seção 14 |
| **Goal violation** | `self.healing.goal.violation.enabled` | Um goal listado em `anomaly.detection.goals` deixa de ser satisfeito | Calcula e executa uma proposta de correção proativamente |
| **Metric anomaly** | `self.healing.metric.anomaly.enabled` | Uma métrica coletada sai fora de padrão de forma abrupta (ex.: bytes-in de uma partição dispara de repente) | Investiga/corrige a causa da anomalia de métrica |
| **Topic anomaly** | `self.healing.topic.anomaly.enabled` | Configuração de tópico viola uma política (ex.: RF abaixo do mínimo aceitável) | Corrige a configuração do tópico ofensor |

Este lab habilita os três primeiros (`kafka-cluster.yaml`) e deixa `metric.anomaly` e
`topic.anomaly` desligados — cada tipo de self-healing automático que você liga é uma
decisão de "eu confio o suficiente nessa detecção para deixar o Cruise Control agir
sozinho", e vale ligar um de cada vez, entendendo o comportamento de cada um isoladamente
antes de empilhar os cinco.

### Broker failure na prática (e sua ressalva)

`self.healing.broker.failure.enabled: "true"` liga o **Broker Failure Detector**: o Cruise
Control monitora quais brokers estão registrados no cluster e, se um broker que antes
existia desaparece, ele calcula — e, com self-healing ligado, **executa automaticamente**
— uma proposta para corrigir qualquer réplica que tenha ficado offline/sub-replicada por
causa dessa perda. Três configs (não expostas no `cruiseControl.config` deste lab, mas bom
saber que existem) controlam a sensibilidade desse detector:
`broker.failure.detection.backoff.ms` (intervalo entre verificações),
`broker.failure.alert.threshold.ms` (quanto tempo o broker fica ausente antes de virar
alerta) e `broker.failure.self.healing.threshold.ms` (quanto tempo até o self-healing
disparar de fato) — o comportamento padrão já é conservador o suficiente para não reagir a
um blip de rede de alguns segundos.

> **Ressalva que vale ouro num vídeo técnico, confirmada testando ao vivo:** neste lab, os
> brokers usam storage `persistent-claim` (PVC). Se você rodar `kubectl delete pod
> my-cluster-broker-0 -n kafka` para "simular uma falha", o StrimziPodSet recria o pod com
> o **mesmo `nodeId`** e **reconecta a mesma PVC** — do ponto de vista do cluster Kafka,
> isso é só um restart (o broker sai e volta com os mesmos dados), não uma falha real de
> broker:
> ```bash
> kubectl get pod my-cluster-broker-0 -n kafka -o jsonpath='{.spec.nodeName}'
> kubectl delete pod my-cluster-broker-0 -n kafka
> kubectl wait pod my-cluster-broker-0 -n kafka --for=condition=Ready --timeout=120s
> # confirme: mesmo nodeId, mesma PVC (data-0-my-cluster-broker-0) — nenhum self-healing disparado
> ```
> O self-healing de verdade do Cruise Control entra em cena quando um broker **some
> definitivamente** do cluster — storage `ephemeral` perdido, node do Kubernetes
> substituído/removido, ou o próprio `KafkaNodePool` reduzido sem passar pelo
> `remove-brokers` da seção 10. Testar isso de forma fiel exige derrubar o node
> físico/VM por baixo do pod, não só o pod — fora do escopo deste lab local em kind, mas
> essencial de entender antes de habilitar self-healing automático em produção: você quer
> ter certeza de que ele só dispara para perdas **reais**, não para todo restart de rolling
> update.

> **Goal violation self-healing merece atenção redobrada.** Diferente de broker/disk
> failure (eventos discretos, claramente "algo quebrou"), um goal violation pode ser
> disparado por algo tão comum quanto um pico de tráfego temporário em `clickstream.raw`
> — e o self-healing, se habilitado, vai reagir com uma proposta de rebalanceamento real,
> movendo dados de verdade, sem intervenção humana. `anomaly.detection.goals` (que precisa
> ser subconjunto de `self.healing.goals`) é o que define quais goals contam pra esse
> gatilho — vale restringir essa lista aos goals que você realmente quer que disparem ação
> automática, não usar o `default.goals` inteiro.

Sem self-healing habilitado para um tipo, o Cruise Control ainda **detecta e notifica** a
anomalia (via Anomaly Notifier — webhook/e-mail configurável) sem agir — uma forma de ter
visibilidade sem dar autonomia total à automação, útil enquanto você ainda não confia o
suficiente pra ligar o self-healing daquele tipo.

## 17. Automação Total: `autoRebalance`

Tudo que fizemos nas seções 9/10 — escalar o node pool, depois aplicar e aprovar
manualmente um `KafkaRebalance` — pode ser **totalmente automatizado** com
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

Os `template`s referenciados são `KafkaRebalance` normais, mas marcados com a anotação
`strimzi.io/rebalance-template: "true"` ([`kafkarebalance-autoscale-templates.yaml`](kafkarebalance-autoscale-templates.yaml)) —
isso os transforma em **configuração-base**, não em pedidos de rebalance de verdade. Não
declare `mode` nem `brokers` neles: o Cluster Operator preenche os dois automaticamente no
momento em que detecta um evento de scaling, usando o template só para o resto da spec
(goals, throttle, etc.).

Até aqui `autoRebalance` não estava habilitado no `kafka-cluster.yaml` (ver ressalva na
seção 6) — habilite agora, aplicando os templates e adicionando o bloco ao `Kafka` CR:

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

Teste escalando o pool sem aplicar nenhum `KafkaRebalance` manualmente:

```bash
kubectl scale kafkanodepool broker --replicas=4 -n kafka

# observe um KafkaRebalance aparecer sozinho, sem você ter aplicado nada:
kubectl get kafkarebalance -n kafka -w

# o Kafka CR também reflete o estado do auto-rebalance:
kubectl get kafka my-cluster -n kafka -o jsonpath='{.status.autoRebalance}'; echo
```

Diferente do fluxo manual, **o `autoRebalance` não espera sua aprovação** — o objeto
gerado automaticamente já nasce aprovado e executa sozinho assim que a proposta fica
pronta. É automação de verdade: você decide a política uma vez (o template), e o operator
aplica ela toda vez que o cluster escala.

> **Ressalva de produção (issue recente, ainda relevante):** existe um caso documentado em
> que o `autoRebalance` **silenciosamente não dispara** — se o Cruise Control estiver no
> meio de um rolling restart no momento exato do evento de scaling, uma instância antiga
> pode receber o pedido de rebalance sem ainda ter informação de capacidade do broker novo,
> retornar erro, e o `KafkaAutoRebalancingReconciler` acaba **descartando** o
> `KafkaRebalance` gerado sem nunca completar o rebalance — sem alertar você. O workaround
> documentado é simples: se você desconfiar que isso aconteceu (cluster escalou, mas o
> broker novo continua vazio depois de alguns minutos), aplique um `KafkaRebalance` manual
> de `add-brokers` (seção 9 deste Day) pra forçar. Não confie cegamente no `autoRebalance`
> logo depois de fazer upgrade/restart do próprio Cruise Control — confirme visualmente que
> o rebalance de fato aconteceu.
> ([issue original](https://github.com/strimzi/strimzi-kafka-operator/issues/11296))

## 18. Segurança da API REST do Cruise Control

A API REST do Cruise Control permite operações potencialmente destrutivas — decomissionar
broker, mover réplicas em massa, pausar/retomar sampling. Por padrão, o Strimzi já sobe o
Cruise Control com:

- **HTTP Basic Auth + TLS habilitados.**
- Dois usuários internos automáticos: **`admin`** (usado pelo próprio operator para
  orquestrar tudo que vimos até aqui) e **`healthcheck`** (só para o readiness probe).

Se você (ou uma ferramenta de terceiros, ou um dashboard customizado) precisa falar
diretamente com a API — sem passar pelo `KafkaRebalance` — o Strimzi permite declarar
usuários adicionais via `cruiseControl.apiUsers`, com dois papéis possíveis:

| Papel | Acesso |
|---|---|
| `VIEWER` | Endpoints leves: `kafka_cluster_state`, `user_tasks`, `review_board` |
| `USER` | Todos os endpoints `GET`, exceto `bootstrap`/`train` |
| (implícito) `ADMIN` | Todos os endpoints — reservado para o Strimzi internamente |

```yaml
# Ilustrativo — requer um Secret com as credenciais referenciado aqui
cruiseControl:
  apiUsers:
    type: hash
    valueFrom:
      secretKeyRef:
        name: cruise-control-api-users
        key: cruise-control-auth.txt
```

> **Por que isso importa:** muito tutorial de Cruise Control "puro" (fora do Strimzi) roda
> com `webserver.security.enable: false` pra simplificar a demo — e às vezes isso vaza pra
> configuração de produção copiada e colada. No Strimzi, desligar isso é um passo
> **explícito e deliberado** (`webserver.security.enable`/`webserver.ssl.enable` em
> `cruiseControl.config`), não o default. Não desligue a menos que você tenha um motivo
> concreto e uma rede já isolada o suficiente para compensar.

## 19. Problemas Conhecidos em Produção

Curadoria de issues reais que valem a pena conhecer antes de operar Cruise Control sério em
produção — cada uma já foi mencionada em contexto nas seções acima; aqui está a lista
consolidada com link direto:

| Problema | Onde neste README | Issue/Discussão |
|---|---|---|
| `hard.goals` não significa "deve ser satisfeito", e sim "deve ser executado" | Seção 11 | [strimzi #9546](https://github.com/orgs/strimzi/discussions/9546) |
| CPU capacity assume 1 core por broker sem `brokerCapacity.cpu` explícito | Seção 12 | [strimzi #5951](https://github.com/strimzi/strimzi-kafka-operator/issues/5951) |
| Capacidade de rede default (10MB/s) derruba `NetworkInboundCapacityGoal` com carga real, mesmo em kind | Seção 12 | Reproduzido neste lab (sem issue pública associada) |
| `add-brokers` contra um broker recém-criado retorna `NullPointerException` em `BrokerCapacityInfo.capacity()` antes da 1ª janela de amostragem | Seção 9 | Reproduzido neste lab (sem issue pública associada) |
| `KafkaTopic` fica preso em `Terminating` se apagado depois (ou junto) do `Kafka` CR — o Topic Operator morre antes de remover o finalizer | Seção 22 | Reproduzido neste lab (sem issue pública associada) |
| Concorrência/throttle configurados como 0 travam o rebalance (não é "ilimitado") | Seção 15 | [strimzi #7167](https://github.com/orgs/strimzi/discussions/7167) |
| `replicaMovementStrategies` no `KafkaRebalance` derruba a requisição com `400 Bad Request` / `Failed to parse parameters` | Seção 15 | Reproduzido neste lab (sem issue pública associada) |
| `brokerCapacity.overrides`/`moveReplicasOffVolumes` com um ID de `controller` (não-broker) falham silenciosamente ou com `IllegalArgumentException` | Seções 12 e 14 | Reproduzido neste lab (sem issue pública associada) |
| `rebalanceDisk`/JBOD rejeitado incorretamente em `KafkaNodePool` (corrigido) | Seção 14 | [strimzi #10280](https://github.com/strimzi/strimzi-kafka-operator/issues/10280) |
| `autoRebalance` pode não disparar durante rolling restart do Cruise Control | Seção 17 | [strimzi #11296](https://github.com/strimzi/strimzi-kafka-operator/issues/11296) |
| Mensagens de erro genéricas no `status` do `KafkaRebalance` — causa real só no log do pod | Todas as seções de rebalance | [strimzi #8444](https://github.com/strimzi/strimzi-kafka-operator/issues/8444) |
| KRaft: nodes `controller`-only usam quorum estático — Cruise Control não os rebalanceia | Geral | Documentação Strimzi sobre KRaft quorum estático |
| Cliente do Cruise Control confia na chave pública do servidor em vez da Cluster CA — pode conflitar com renovação de CA em paralelo a um rebalance | Watch-list (issue recente, em aberto) | [strimzi #12442](https://github.com/strimzi/strimzi-kafka-operator/issues/12442) |
| Metrics Reporter do Cruise Control para de funcionar atrás de um service mesh (Istio/Cilium) interceptando o tráfego interno — não é bug do Strimzi, é incompatibilidade não suportada | Watch-list, só relevante fora de kind | [strimzi #11869](https://github.com/orgs/strimzi/discussions/11869), [strimzi #12200](https://github.com/orgs/strimzi/discussions/12200) |

## 20. Limites Arquiteturais do Cruise Control

Uma seção deliberadamente cética, porque especialista em Kafka não é quem só elogia a
ferramenta — é quem sabe onde ela para. Cruise Control é excelente no que se propõe a
fazer, mas ele opera **dentro** de uma restrição arquitetural que nenhuma otimização de
software resolve: **dados de partição vivem em disco local do broker.** Isso implica:

- **"Conservação de estado":** se uma réplica acumulou um log grande e o novo lugar
  escolhido é outro broker, alguém precisa copiar aqueles bytes inteiros pela rede. Nenhum
  otimizador "apaga" os bytes — o Analyzer pode decidir *o quê* mover em segundos, mas o
  Executor ainda precisa fisicamente copiar terabytes se for o caso. É por isso que
  throttle (seção 15) é sempre um trade-off, nunca uma cura: throttle baixo protege
  tráfego de produção mas estica a janela de rebalance; throttle alto termina rápido mas
  compete com produtores/consumidores reais pela mesma rede.
- **Partição quente não é resolvida por rebalance de broker.** Se uma única partição tem
  throughput desproporcional (um hot key, um tenant grande demais numa partição
  compartilhada), mover essa partição pra outro broker só move o problema — o
  `LeaderReplicaDistributionGoal` distribui *quantas* partições cada broker lidera, não
  reduz a carga de uma partição individual desbalanceada dentro do seu próprio tráfego.
  Isso é modelagem de tópico/particionamento, não capacity planning de cluster.
- **Um broker novo começa vazio.** `add-brokers` (seção 9) só ajuda depois que réplicas ou
  lideranças migram pra ele — capacidade de CPU/rede chega antes de tráfego balanceado
  chegar junto. Diferente de escalar compute stateless (onde um pod novo já processa
  tráfego imediatamente), um broker novo é, por um tempo, um investimento sem retorno até
  o rebalance terminar.

Nada disso é motivo pra não usar Cruise Control — é o contrário: entender essas restrições
é o que te permite prever quanto tempo um rebalance real vai levar, e por que "adicionar
mais um broker" não é uma correção instantânea. Arquiteturas mais recentes de Kafka que
desacoplam armazenamento de broker (tiered storage, ou storage compartilhado/object
storage) atacam exatamente essa restrição — vale ter isso no radar se hot partitions e
rebalance lento forem uma dor recorrente no seu cluster, mas isso é assunto pra outro Day.

## 21. Cenário Completo: Disco Cheio às 3h da Manhã

Juntando tudo — um walkthrough de incidente do jeito que aconteceria de verdade:

1. **03:47 — alerta de disco.** Um broker está em 88% de uso de disco (bem acima do
   `disk.capacity.threshold` de 80% — seção 11). `DiskCapacityGoal`, se você pedisse uma
   proposta agora, já estaria violado.
   ```bash
   kubectl -n kafka run kafka-topics-describe -ti --image=quay.io/strimzi/kafka:1.1.0-kafka-4.3.0 \
     --rm=true --restart=Never -- bin/kafka-topics.sh --describe \
     --bootstrap-server my-cluster-kafka-bootstrap:9092
   kubectl logs -n kafka deployment/my-cluster-cruise-control --tail=100
   ```
2. **Decisão: emergência de disco, não manutenção completa.** Aplica-se
   [`kafkarebalance-disk-incident.yaml`](kafkarebalance-disk-incident.yaml) (seção 13) —
   só goals de disco, `skipHardGoalCheck: true`, `payments.processed` protegido por
   `excludedTopics`.
   ```bash
   kubectl apply -f kafkarebalance-disk-incident.yaml -n kafka
   kubectl describe kafkarebalance disk-incident-rebalance -n kafka
   ```
3. **Revisão antes de aprovar.** Confirma no `Optimization Result` que a redução de disco
   é suficiente e que nenhuma réplica de `payments.*` foi tocada.
   ```bash
   kubectl annotate kafkarebalance disk-incident-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
   kubectl get kafkarebalance disk-incident-rebalance -n kafka -w
   ```
4. **Depois que o disco normaliza, reconciliar de verdade.** O `skipHardGoalCheck` da
   etapa 2 deixou rede/CPU/rack fora da verificação — de manhã, com o cluster estável,
   roda-se um `kafkarebalance-full.yaml` completo (seção 8), com todos os hard goals, pra
   garantir que a correção de emergência não deixou nenhum outro goal quebrado.
   ```bash
   kubectl apply -f kafkarebalance-full.yaml -n kafka
   kubectl annotate kafkarebalance full-rebalance strimzi.io/rebalance=approve -n kafka --overwrite
   ```

Esse é o padrão real: **resposta rápida e escopada** para o sintoma agudo, seguida de
**reconciliação completa** depois que a pressão passa — não um único rebalance tentando
fazer as duas coisas ao mesmo tempo.

## 22. Cleanup

```bash
kubectl -n kafka delete kafkatopic --all
kubectl -n kafka delete kafkarebalance --all
kubectl -n kafka delete $(kubectl get strimzi -o name -n kafka)
kubectl get pvc -n kafka   # devem sumir sozinhas por causa do deleteClaim: true
kind delete cluster --name strimzi-day7
```

> **Por que apagar `KafkaTopic` antes:** quem remove o finalizer `strimzi.io/topic-operator`
> de cada `KafkaTopic` é o Topic Operator, que roda dentro do pod do `entity-operator` — e
> esse pod morre junto quando o `Kafka` CR é apagado. Reproduzimos neste lab o que
> acontece se você deletar tudo de uma vez com `kubectl delete $(kubectl get strimzi -o
> name)` sem separar os `KafkaTopic` primeiro: é uma corrida real, e se o
> `Kafka`/`entity-operator` for removido antes do Topic Operator processar a exclusão dos
> tópicos, os `KafkaTopic` ficam presos para sempre em `Terminating` com o finalizer nunca
> removido. Apagar os tópicos (e os `KafkaRebalance`, que dependem do `Kafka` existir)
> primeiro evita esse problema. Se você já caiu nessa armadilha, o jeito de destravar é
> forçar a remoção do finalizer:
> `kubectl patch kafkatopic <nome> -n kafka --type=merge -p '{"metadata":{"finalizers":[]}}'`.

## 23. Referências

| Recurso | URL |
|---|---|
| Strimzi — Cruise Control for cluster rebalancing | https://strimzi.io/docs/operators/latest/deploying#con-kafka-cruise-control-str |
| Strimzi — KafkaRebalance API Reference | https://strimzi.io/docs/operators/latest/configuring#type-KafkaRebalance-reference |
| Strimzi — Blog: Cruise Control (introdução original, 2020) | https://strimzi.io/blog/2020/06/15/cruise-control/ |
| Strimzi — Blog: Moving data between JBOD disks using Cruise Control | https://strimzi.io/blog/2025/02/13/moving-data-between-jbod-disks-using-cruise-control/ |
| Strimzi — Blog: Auto-rebalancing on cluster scaling | https://strimzi.io/blog/2024/11/25/autorebalancing-on-scaling/ |
| Strimzi — Proposal 078: Auto-rebalancing on cluster scaling | https://github.com/strimzi/proposals/blob/main/078-auto-rebalancing-cluster-scaling.md |
| Red Hat — Streams for Apache Kafka (KRaft): Cruise Control concepts | https://docs.redhat.com/en/documentation/red_hat_streams_for_apache_kafka/2.7/html/using_streams_for_apache_kafka_on_rhel_in_kraft_mode/cruise-control-concepts-str |
| Axual — Apache Kafka Cruise Control (visão prática) | https://axual.com/blog/apache-kafka-cruise-control |
| Confluent — Kafka Summit London 2023: An Introduction to Kafka Cruise Control | https://www.confluent.io/events/kafka-summit-london-2023/an-introduction-to-kafka-cruise-control/ |
| Cruise Control — repositório (fork ativo, pós-LinkedIn) | https://github.com/cruise-control-for-kafka/cruise-control |
| Cruise Control (LinkedIn) — Wiki: Configurations (goals, thresholds) | https://github.com/linkedin/cruise-control/wiki/Configurations |
| Cruise Control — REST APIs | https://github.com/linkedin/cruise-control/wiki/REST-APIs |
| `hard.goals` execução vs satisfação — discussão | https://github.com/orgs/strimzi/discussions/9546 |
| CPU capacity — issue do default de 1 core | https://github.com/strimzi/strimzi-kafka-operator/issues/5951 |
| Concorrência zerada trava rebalance — discussão | https://github.com/orgs/strimzi/discussions/7167 |
| `rebalanceDisk` rejeitado em `KafkaNodePool` (corrigido) | https://github.com/strimzi/strimzi-kafka-operator/issues/10280 |
| `autoRebalance` não dispara durante rolling restart | https://github.com/strimzi/strimzi-kafka-operator/issues/11296 |
| Mensagens de erro genéricas no `KafkaRebalance` | https://github.com/strimzi/strimzi-kafka-operator/issues/8444 |
| Cliente Cruise Control e Cluster CA (issue em aberto) | https://github.com/strimzi/strimzi-kafka-operator/issues/12442 |
| Cruise Control Metrics Reporter + Istio (upgrade quebra conectividade) | https://github.com/orgs/strimzi/discussions/11869 |
| Cruise Control Metrics Reporter + Istio/Cilium em KRaft | https://github.com/orgs/strimzi/discussions/12200 |
| AutoMQ — limites arquiteturais do Cruise Control (perspectiva crítica) | https://www.automq.com/blog/kafka-rebalancing-issues-cruise-control-architecture |
| kind | https://kind.sigs.k8s.io/ |
| Release usada neste lab (1.1.0) | https://github.com/strimzi/strimzi-kafka-operator/releases/tag/1.1.0 |

---

> Parte da série **Espetinho de Kafka** — Strimzi Day 7: Cruise Control Avançado.
> Day anterior: [Cruise Control — Introdução](../Day6-CruiseControl/).
