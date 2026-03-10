# Kafka MirrorMaker 2 na Prática

> **Objetivo:** Entender o MirrorMaker 2, suas arquiteturas e simular um cenário Active-Active entre dois clusters Kafka na máquina local com Docker.

---

## Índice

1. [O que é o MirrorMaker 2](#1-o-que-é-o-mirrormaker-2)
2. [Arquiteturas de Replicação](#2-arquiteturas-de-replicação)
3. [Conceitos Fundamentais](#3-conceitos-fundamentais)
4. [Lab Local com Docker](#4-lab-local-com-docker)
5. [Active-Passive — Passo a Passo](#5-active-passive--passo-a-passo)
6. [Active-Active — Passo a Passo](#6-active-active--passo-a-passo)
7. [Verificação e Monitorização](#7-verificação-e-monitorização)
8. [Testando Mensagens Grandes (> 1MB)](#8-testando-mensagens-grandes--1mb)
9. [Dicas para Produção](#9-dicas-para-produção)
10. [Referências](#10-referências)

---

## 1. O que é o MirrorMaker 2

O **MirrorMaker 2 (MM2)** é a solução nativa do Apache Kafka para replicação de dados entre clusters. Introduzido no Kafka 2.4, baseia-se no framework **Kafka Connect** e substitui o MirrorMaker 1 com uma abordagem mais robusta e configurável.

**O que o MM2 replica:**

| Componente | Descrição |
|-----------|-----------|
| Mensagens | Preserva key, value, headers e timestamp original |
| Tópicos | Partições, replication factor, configurações (retention, cleanup policy) |
| Consumer Groups | Offsets sincronizados via checkpoints |
| ACLs | Opcional (`sync.topic.acls.enabled`) |

**Casos de uso típicos:**

- Migração entre clusters sem downtime
- Disaster Recovery (DR) com failover automático
- Federação multi-região (Global Event Bus)
- Separação de ambientes (prod → staging para replay)

---

## 2. Arquiteturas de Replicação

### 2.1 Active-Passive (one-way)

Replicação unidirecional. O cluster destino é um espelho de leitura do cluster origem. Usado principalmente para **DR e backup**.

```
┌──────────────────┐      MM2       ┌──────────────────┐
│  Cluster Origem  │ ─────────────▶ │  Cluster Destino │
│  (Activo)        │                │  (Passivo / DR)  │
│                  │                │                  │
│  Produtores ────▶│                │           ──────▶│ Consumidores
│  Consumidores ◀──│                │                  │   (apenas DR)
└──────────────────┘                └──────────────────┘
```

**Características:**
- Simples de configurar e operar
- Sem risco de loop de mensagens
- Failover requer switch manual dos produtores/consumidores
- Offsets podem divergir entre clusters

---

### 2.2 Active-Active (bidirectional)

Replicação bidirecional. Ambos os clusters recebem produtores e replicam entre si. Usado para **alta disponibilidade, multi-região e zero downtime**.

```
┌──────────────────┐                ┌──────────────────┐
│   Cluster A      │ ─── MM2 ──────▶│   Cluster B      │
│                  │◀──── MM2 ──────│                  │
│  Produtores ────▶│                │◀──── Produtores  │
│  Consumidores ◀──│                │           ──────▶│ Consumidores
└──────────────────┘                └──────────────────┘
```

**Características:**
- Ambos os clusters estão activos para leitura e escrita
- Requer mecanismo de prevenção de loops (ver secção 3.3)
- Failover transparente: produtores redirecionam sem perda de dados
- Maior complexidade operacional

---

### 2.3 Hub-and-Spoke

Um cluster central (hub) agrega dados de múltiplos clusters regionais (spokes). Usado em **federação global de eventos**.

```
          ┌──────────────┐
          │  Hub Central │
          │  (Agregador) │
          └──────┬───────┘
        ▲        ▲        ▲
        │        │        │
┌───────┴─┐  ┌──┴──────┐  ┌┴────────┐
│ Spoke A │  │ Spoke B │  │ Spoke C │
│ (EU)    │  │ (US)    │  │ (APAC)  │
└─────────┘  └─────────┘  └─────────┘
```

---

### 2.4 Fan-out / Aggregate

O inverso do Hub-and-Spoke: um cluster central distribui para múltiplos destinos, ou múltiplos origens consolidam para um destino.

```
┌──────────────┐         ┌──────────────┐
│  Origem A   │──▶ MM2 ──▶│  Destino X  │
├──────────────┤         ├──────────────┤
│  Origem B   │──▶ MM2 ──▶│  Destino Y  │
├──────────────┤         └──────────────┘
│  Origem C   │──▶ MM2 ──▶  (agregado)
└──────────────┘
```

---

## 3. Conceitos Fundamentais

### 3.1 Replication Policy

A `replication.policy.class` define como os nomes dos tópicos são tratados no cluster destino.

| Policy | Comportamento | Quando usar |
|--------|--------------|-------------|
| `DefaultReplicationPolicy` | Prefixa com o alias: `source.topicName` | Active-Active (loop prevention nativo) |
| `IdentityReplicationPolicy` | Mantém o nome idêntico: `topicName` | Migrações, Active-Passive |

**DefaultReplicationPolicy — prevenção de loop nativa:**

```
Cluster A produz:  orders
Cluster B recebe:  A.orders       → não replicado de volta (loop prevenido pelo prefixo)
Cluster B produz:  payments
Cluster A recebe:  B.payments     → não replicado de volta
```

**IdentityReplicationPolicy — atenção ao loop:**

Com nomes idênticos em ambos os clusters, o MM2 utilizaria headers para detectar a proveniência da mensagem e evitar loops. A filtragem é feita internamente pelo próprio MirrorSourceConnector.

---

### 3.2 Sincronização de Consumer Groups

O MM2 inclui o **MirrorCheckpointConnector** que sincroniza os offsets dos consumer groups entre clusters. Isso permite que, num failover, os consumidores retomem exactamente de onde pararam.

```
Cluster A:  consumer-group-X  →  topic  →  offset 1500
                  │
      MirrorCheckpointConnector
                  │
Cluster B:  consumer-group-X  →  A.topic  →  offset 1498  (traduzido)
```

**Configurações relevantes:**

```properties
sync.group.offsets.enabled = true          # activa a sincronização
sync.group.offsets.interval.seconds = 60   # frequência de sincronização
emit.checkpoints.enabled = true            # emite checkpoints periódicos
emit.checkpoints.interval.seconds = 60
```

> **Nota:** Os offsets não são directamente transferíveis — o MM2 faz uma tradução por timestamp entre os offsets do cluster origem e destino.

---

### 3.3 Prevenção de Loop em Active-Active

O maior risco em topologias bidirecionais é criar um loop infinito de mensagens. Existem duas abordagens principais:

**Abordagem 1 — DefaultReplicationPolicy (mais simples):**
Prefixo automático impede re-replicação. Cluster B recebe `A.topicName` — como o nome é diferente, não é replicado de volta. Simples mas força nomes de tópicos diferentes nos dois lados.

**Abordagem 2 — IdentityReplicationPolicy + Transforms SMT (recomendada):**
Mantém nomes de tópicos idênticos em ambos os clusters. A prevenção de loop é feita via dois transforms encadeados por fluxo:

```
Fluxo A→B:
  filterFromB  → descarta se header "from_cluster_B" presente  (veio do B, não replicar)
  markFromA    → insere header "from_cluster_A=true"            (marca como originado em A)

Fluxo B→A:
  filterFromA  → descarta se header "from_cluster_A" presente  (veio do A, não replicar)
  markFromB    → insere header "from_cluster_B=true"            (marca como originado em B)
```

Esta abordagem é a usada pelo `mm2-active-active.properties` deste lab e é a mais adequada para produção onde os consumidores precisam de subscrever o mesmo nome de tópico em qualquer cluster.

---

### 3.4 Tópicos Internos Criados pelo MM2

Ao iniciar, o MM2 cria automaticamente os seguintes tópicos internos:

| Tópico | Propósito |
|--------|-----------|
| `mm2-configs.{cluster}.internal` | Configurações dos connectors |
| `mm2-offsets.{cluster}.internal` | Offsets dos connectors |
| `mm2-status.{cluster}.internal` | Status dos connectors |
| `mm2-offset-syncs.{cluster}.internal` | Mapeamento source offset → target offset |
| `{cluster}.checkpoints.internal` | Checkpoints de consumer groups |
| `heartbeats` | Heartbeats entre clusters |

---

## 4. Lab Local com Docker

### Pré-requisitos

- Docker + Docker Compose
- Apache Kafka instalado localmente (para executar o `connect-mirror-maker.sh`)
  - Download: https://kafka.apache.org/downloads
  - Versão recomendada: **3.8.x** ou **4.0.x**

> O Kafka vem com o MirrorMaker 2 incluído em `bin/connect-mirror-maker.sh`. Não é necessário instalar nada adicional além do Kafka.

### Estrutura do Lab

```
Day9-MirrorMaker/
├── docker-compose.yml           # 2 clusters Kafka + Kafbat UI
├── mm2-active-passive.properties  # Config Active-Passive
├── mm2-active-active.properties   # Config Active-Active
└── README.md
```

### Subir os Clusters

```bash
docker compose up -d
```

Aguardar ~10 segundos e verificar:

```bash
docker compose ps
```

| Container | Porta | Descrição |
|-----------|-------|-----------|
| `kafka-source` | 9092 | Cluster origem |
| `kafka-target` | 9094 | Cluster destino |
| `kafbat-ui` | 8090 | Interface gráfica |

Aceder ao UI: **http://localhost:8090**

---

## 5. Active-Passive — Passo a Passo

### Configuração: `mm2-active-passive.properties`

```properties
clusters = source, target

source.bootstrap.servers = localhost:9092
target.bootstrap.servers = localhost:9094

source->target.enabled = true
target->source.enabled = false

replication.policy.class = org.apache.kafka.connect.mirror.IdentityReplicationPolicy
replication.factor = 1

topics.exclude = __.*,.*\.internal,.*-internal,mm2-.*,heartbeats

sync.group.offsets.enabled = true
sync.topic.configs.enabled = true
sync.topic.acls.enabled = false

checkpoints.topic.replication.factor = 1
heartbeats.topic.replication.factor = 1
offset-syncs.topic.replication.factor = 1
offset.storage.replication.factor = 1
status.storage.replication.factor = 1
config.storage.replication.factor = 1

tasks.max = 3
```

> **Nota:** O ficheiro `mm2-active-passive.properties` usa endereços internos Docker. Para executar o MM2 localmente (fora do Docker), substituir `kafka-source:29092` por `localhost:9092` e `kafka-target:39094` por `localhost:9094`.

### Executar o MirrorMaker 2

```bash
# A partir do directório de instalação do Kafka
export KAFKA_HOME=/opt/kafka  # ajustar para o seu caminho

$KAFKA_HOME/bin/connect-mirror-maker.sh mm2-active-passive.properties
```

### Testar a Replicação

**Terminal 1 — Criar tópico e produzir mensagens no cluster origem:**

```bash
# Criar tópico no source
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders --partitions 3 --replication-factor 1

# Produzir mensagens
for i in {1..5}; do
  echo "order-$i:value-$i" | kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic orders \
    --property "parse.key=true" \
    --property "key.separator=:"
done
```

**Terminal 2 — Consumir no cluster destino (deve aparecer as mensagens replicadas):**

```bash
kafka-console-consumer.sh \
  --bootstrap-server localhost:9094 \
  --topic orders \
  --from-beginning \
  --property print.key=true \
  --property print.offset=true \
  --property print.partition=true
```

**Verificar que o tópico foi criado no destino:**

```bash
kafka-topics.sh --bootstrap-server localhost:9094 --list
```

### Verificar Consumer Group Sync

```bash
# Criar um consumer group no source
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic orders \
  --group app-consumer-group \
  --from-beginning \
  --max-messages 5

# Aguardar ~60 segundos (sync.group.offsets.interval.seconds)
# Verificar se o offset foi sincronizado no target
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9094 \
  --describe --group app-consumer-group
```

---

## 6. Active-Active — Passo a Passo

### Estratégia: Header-based loop prevention com SMT

A configuração `mm2-active-active.properties` usa **`IdentityReplicationPolicy`** (nomes de tópicos idênticos em ambos os clusters) combinada com **Transforms SMT** para prevenir loops infinitos em vez de depender de prefixos automáticos.

**Como funciona:**

```
Cluster A produz mensagem "orders" (sem header)
       │
       ▼
  Fluxo A→B
  ┌─────────────────────────────────────┐
  │ 1. filterFromB: tem "from_cluster_B"?│
  │    NÃO → passa                       │
  │ 2. markFromA: insere "from_cluster_A"│
  └─────────────────────────────────────┘
       │
       ▼
Cluster B recebe "orders" com header "from_cluster_A=true"
       │
       ▼
  Fluxo B→A (tenta replicar de volta)
  ┌─────────────────────────────────────┐
  │ 1. filterFromA: tem "from_cluster_A"?│
  │    SIM → DESCARTA  ✓ loop prevenido  │
  └─────────────────────────────────────┘
```

### Configuração resumida: `mm2-active-active.properties`

```properties
clusters = A, B
connector.client.config.override.policy = All
header.converter = org.apache.kafka.connect.storage.StringConverter
replication.policy.class = org.apache.kafka.connect.mirror.IdentityReplicationPolicy

A.bootstrap.servers = localhost:9092
B.bootstrap.servers = localhost:9094

A->B.enabled = true
A->B.topics = .*
A->B.transforms = filterFromB, markFromA
A->B.transforms.filterFromB.type      = org.apache.kafka.connect.transforms.Filter
A->B.transforms.filterFromB.predicate = hasHeaderFromB
A->B.transforms.filterFromB.negate    = false
A->B.predicates = hasHeaderFromB
A->B.predicates.hasHeaderFromB.type   = org.apache.kafka.connect.transforms.predicates.HasHeaderKey
A->B.predicates.hasHeaderFromB.name   = from_cluster_B
A->B.transforms.markFromA.type             = org.apache.kafka.connect.transforms.InsertHeader
A->B.transforms.markFromA.header           = from_cluster_A
A->B.transforms.markFromA.value.literal    = true
A->B.MirrorHeartbeatConnector.transforms   = none
A->B.MirrorCheckpointConnector.transforms  = none

B->A.enabled = true
B->A.topics = .*
B->A.transforms = filterFromA, markFromB
B->A.transforms.filterFromA.type      = org.apache.kafka.connect.transforms.Filter
B->A.transforms.filterFromA.predicate = hasHeaderFromA
B->A.transforms.filterFromA.negate    = false
B->A.predicates = hasHeaderFromA
B->A.predicates.hasHeaderFromA.type   = org.apache.kafka.connect.transforms.predicates.HasHeaderKey
B->A.predicates.hasHeaderFromA.name   = from_cluster_A
B->A.transforms.markFromB.type            = org.apache.kafka.connect.transforms.InsertHeader
B->A.transforms.markFromB.header          = from_cluster_B
B->A.transforms.markFromB.value.literal   = true
B->A.MirrorHeartbeatConnector.transforms  = none
B->A.MirrorCheckpointConnector.transforms = none

sync.topic.configs.enabled = false
sync.group.offsets.enabled = true
```

> O ficheiro completo com suporte a mensagens grandes (10MB), compressão `lz4` e overrides por fluxo está em `mm2-active-active.properties`.

### Executar o MirrorMaker 2 (Active-Active)

```bash
$KAFKA_HOME/bin/connect-mirror-maker.sh mm2-active-active.properties
```

### Testar a Replicação Bidirecional

**Criar um tópico partilhado em ambos os clusters:**

```bash
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic shared-events --partitions 3 --replication-factor 1

kafka-topics.sh --bootstrap-server localhost:9094 \
  --create --topic shared-events --partitions 3 --replication-factor 1
```

**Produzir no Cluster A e consumir no Cluster B:**

```bash
# Terminal 1 — produzir no A
for i in {1..5}; do
  echo "key-$i:from-cluster-A-$i" | kafka-console-producer.sh \
    --bootstrap-server localhost:9092 \
    --topic shared-events \
    --property "parse.key=true" \
    --property "key.separator=:"
done

# Terminal 2 — consumir no B (deve chegar com header "from_cluster_A")
kafka-console-consumer.sh \
  --bootstrap-server localhost:9094 \
  --topic shared-events \
  --from-beginning \
  --property print.key=true \
  --property print.headers=true
```

**Produzir no Cluster B e consumir no Cluster A:**

```bash
# Terminal 3 — produzir no B
for i in {1..5}; do
  echo "key-$i:from-cluster-B-$i" | kafka-console-producer.sh \
    --bootstrap-server localhost:9094 \
    --topic shared-events \
    --property "parse.key=true" \
    --property "key.separator=:"
done

# Terminal 4 — consumir no A (deve chegar com header "from_cluster_B")
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic shared-events \
  --from-beginning \
  --property print.key=true \
  --property print.headers=true
```

### Validar a Prevenção de Loop com Headers

Usar o `--property print.headers=true` no consumer para confirmar que:

- Mensagens produzidas no **Cluster A** chegam ao **Cluster B** com header `from_cluster_A:true`
- Essas mesmas mensagens **NÃO voltam** ao Cluster A (o `filterFromA` as descarta)

```bash
# Contar mensagens no tópico de cada cluster — devem ser iguais
# (cada cluster só deve ter as suas originais + as replicadas do outro, sem duplicados)
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic shared-events \
  --from-beginning \
  --timeout-ms 3000 \
  --property print.headers=true 2>/dev/null | wc -l

kafka-console-consumer.sh \
  --bootstrap-server localhost:9094 \
  --topic shared-events \
  --from-beginning \
  --timeout-ms 3000 \
  --property print.headers=true 2>/dev/null | wc -l
# Resultado esperado: ambos com o mesmo número de mensagens (sem duplicados infinitos)
```

---

## 7. Verificação e Monitorização

### Tópicos Internos do MM2

Após iniciar o MM2, os seguintes tópicos serão criados automaticamente:

```bash
# Ver todos os tópicos internos
kafka-topics.sh --bootstrap-server localhost:9092 --list | grep -E "mm2|checkpoint|heartbeat"
kafka-topics.sh --bootstrap-server localhost:9094 --list | grep -E "mm2|checkpoint|heartbeat"
```

### Verificar Heartbeats (Saúde do MM2)

```bash
kafka-console-consumer.sh \
  --bootstrap-server localhost:9094 \
  --topic heartbeats \
  --from-beginning \
  --property print.key=true \
  --max-messages 5
```

### Verificar Checkpoints de Consumer Groups

```bash
# Ver os checkpoints sincronizados pelo MM2
kafka-console-consumer.sh \
  --bootstrap-server localhost:9094 \
  --topic source.checkpoints.internal \
  --from-beginning \
  --property print.key=true \
  --max-messages 20
```

### Comparar Tamanho de Tópico entre Clusters

```bash
# Tamanho no cluster origem
kafka-log-dirs.sh --bootstrap-server localhost:9092 \
  --topic-list orders --describe \
  | grep -oP '(?<="size":)\d+' \
  | awk '{ sum += $1 } END { print sum " bytes" }'

# Tamanho no cluster destino
kafka-log-dirs.sh --bootstrap-server localhost:9094 \
  --topic-list orders --describe \
  | grep -oP '(?<="size":)\d+' \
  | awk '{ sum += $1 } END { print sum " bytes" }'
```

### Interface Gráfica — Kafbat UI

Aceder a **http://localhost:8090** para visualizar:

- Tópicos em ambos os clusters
- Consumer groups e offsets
- Mensagens em tempo real
- Tópicos internos do MM2

---

## 8. Testando Mensagens Grandes (> 1MB)

Este lab inclui o script `generate-large-message.py` para gerar payloads JSON realistas com mais de 1MB — ideal para validar a configuração do MM2 com mensagens fora do limite padrão do Kafka.

### Gerar os ficheiros JSON

```bash
# Mensagem única de ~1.2MB (default)
python3 generate-large-message.py

# Mensagem de ~2MB
python3 generate-large-message.py --size 2

# Mensagem de ~5MB
python3 generate-large-message.py --size 5

# Batch de 10 mensagens (~1.2MB cada → ficheiro messages-batch.json)
python3 generate-large-message.py --count 10

# Batch de 5 mensagens de ~2MB cada
python3 generate-large-message.py --size 2 --count 5
```

O script gera ficheiros no formato `key|json_value` (uma mensagem por linha), prontos para consumir com `kafka-console-producer`.

### Criar o tópico com limite de mensagem aumentado

Por padrão, o Kafka limita as mensagens a **1MB**. Antes de produzir, criar o tópico com o limite correcto:

```bash
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic large-messages \
  --partitions 3 --replication-factor 1 \
  --config max.message.bytes=10485760
```

### Produzir uma mensagem grande

```bash
# Gerar o ficheiro
python3 generate-large-message.py --size 1.5

# Produzir (nota: aumentar o buffer do producer também)
kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic large-messages \
  --property "parse.key=true" \
  --property "key.separator=|" \
  --producer-property max.request.size=10485760 \
  < message-large.json
```

### Produzir um batch de mensagens grandes

```bash
python3 generate-large-message.py --count 5 --size 2

kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic large-messages \
  --property "parse.key=true" \
  --property "key.separator=|" \
  --producer-property max.request.size=10485760 \
  < messages-batch.json
```

### Configurar o MM2 para mensagens grandes

Antes de iniciar o MM2, adicionar ao ficheiro `.properties` em uso:

```properties
# Producer: limite de mensagem
producer.max.request.size = 10485760

# Consumer: limite de fetch por partição e total
consumer.max.partition.fetch.bytes = 10485760
consumer.fetch.max.bytes = 10485760
```

Alternativamente, configurar por cluster:

```properties
source.max.partition.fetch.bytes = 10485760
source.fetch.max.bytes = 10485760
target.max.request.size = 10485760
```

### Verificar se a mensagem foi replicada

```bash
# Ver tamanho total do tópico no cluster origem
kafka-log-dirs.sh --bootstrap-server localhost:9092 \
  --topic-list large-messages --describe \
  | grep -oP '(?<="size":)\d+' \
  | awk '{ sum += $1 } END { printf "Source: %d bytes (%.2f MB)\n", sum, sum/1024/1024 }'

# Ver tamanho total no cluster destino
kafka-log-dirs.sh --bootstrap-server localhost:9094 \
  --topic-list large-messages --describe \
  | grep -oP '(?<="size":)\d+' \
  | awk '{ sum += $1 } END { printf "Target: %d bytes (%.2f MB)\n", sum, sum/1024/1024 }'
```

Os dois valores devem ser iguais (ou muito próximos se a replicação ainda estiver a decorrer).

---

## 9. Dicas para Produção

### Versão do Kafka para o MM2

O MM2 deve ser executado com uma versão do cliente Kafka **compatível com ambos os clusters**. Se o cluster mais antigo for 2.6, use Kafka **3.8.x** para executar o MM2 — o Kafka 4.x pode ter incompatibilidades de protocolo com clusters mais antigos.

### IdentityReplicationPolicy em Active-Passive

Para migrações onde os nomes dos tópicos devem ser idênticos no destino:

```properties
replication.policy.class = org.apache.kafka.connect.mirror.IdentityReplicationPolicy
sync.topic.configs.enabled = false  # se os tópicos já foram criados manualmente
```

### Mensagens Grandes (>1MB)

O MM2 pode falhar ao replicar mensagens que excedam os limites padrão. Configurar em ambos os clusters e no MM2:

```properties
# No ficheiro de configuração do MM2
source.max.partition.fetch.bytes = 5242880   # 5MB
target.max.request.size = 5242880            # 5MB
producer.max.request.size = 5242880
consumer.max.partition.fetch.bytes = 5242880
fetch.max.bytes = 5242880
```

### Excluir Tópicos Internos do Kafka / Managed Services

```properties
topics.exclude = __.*,                          # tópicos internos Kafka
                 .*\.internal,                  # tópicos internos MM2
                 .*-internal,                   # variante com hífen
                 mm2-.*,                        # tópicos MM2
                 heartbeats,                    # heartbeat MM2
                 _schemas,                      # Schema Registry
                 __amazon_msk_.*               # tópicos internos AWS MSK
```

### Sincronização de Consumer Groups — Limitações

O `MirrorCheckpointConnector` pode falhar em grupos que:
- Não têm atividade recente no tópico
- Consomem tópicos excluídos da replicação

Nesses casos, criar manualmente os consumer groups no cluster destino consumindo algumas mensagens e depois resetar para `latest`.

### Replication Factor em Produção

Usar sempre `replication.factor = 3` em produção para todos os tópicos internos do MM2:

```properties
checkpoints.topic.replication.factor = 3
heartbeats.topic.replication.factor = 3
offset-syncs.topic.replication.factor = 3
offset.storage.replication.factor = 3
status.storage.replication.factor = 3
config.storage.replication.factor = 3
```

### Rollback por Timestamp

Para fazer rollback de consumer groups para um ponto no tempo:

```bash
kafka-consumer-groups.sh \
  --bootstrap-server <BROKERS> \
  --command-config client.conf \
  --group <GROUP> \
  --topic <TOPIC> \
  --reset-offsets \
  --to-datetime 2026-01-15T10:00:00.000 \
  --execute
```

---

## 10. Referências

| Recurso | URL |
|---------|-----|
| Documentação Oficial MM2 | https://kafka.apache.org/documentation/#georeplication |
| KIP-382 (MirrorMaker 2) | https://cwiki.apache.org/confluence/display/KAFKA/KIP-382%3A+MirrorMaker+2.0 |
| Apache Kafka Downloads | https://kafka.apache.org/downloads |
| Kafbat UI | https://github.com/kafbat/kafka-ui |
| AWS MM2 Migration Sample | https://github.com/aws-samples/mirrormaker2-msk-migration |
| Red Hat Demystifying Kafka mirrormaker 2 | https://developers.redhat.com/articles/2023/11/13/demystifying-kafka-mirrormaker-2-use-cases-and-architecture#architecture_design_scenarios|
| Lenses |https://lenses.io/blog/kafka-replication-mirrormaker2-complexity|
| Conduktor| https://www.conduktor.io/glossary/kafka-mirrormaker-2-for-cross-cluster-replication|
| Azure MM2 | https://learn.microsoft.com/pt-pt/azure/hdinsight/kafka/kafka-mirrormaker-2-0-guide|
| Strimz Intro| https://strimzi.io/blog/2020/03/30/introducing-mirrormaker2/|
| GitHub - Kafka Mirror|https://github.com/mordp1/kafka-mirror-java |

---

> Parte da série **Espetinho de Kafka** — Day 9: MirrorMaker 2
