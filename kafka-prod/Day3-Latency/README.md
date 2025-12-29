# Apache Kafka - Otimização para Latência

## 🎯 Objetivo

Minimizar o **tempo decorrido end-to-end** para movimentar mensagens de producers para brokers para consumers. Para baixa latência, queremos que os dados se movam o mais rápido possível.

## 💡 Conceito Chave

**Muitos parâmetros de configuração do Kafka já têm valores padrão otimizados para latência!**

Geralmente não é necessário ajustá-los, mas vamos revisar os parâmetros críticos para reforçar o entendimento de como funcionam.

## ⚖️ Trade-off Principal: Partições

### O Dilema das Partições

```
Mais Partições {
    ✅ Maior Throughput (mais paralelismo)
    ❌ Maior Latência (mais tempo para replicar)
}
```

### Por que Mais Partições Aumentam Latência?

**Problema:** Um broker usa **uma única thread por padrão** para replicar dados de outro broker.

```
┌─────────────────────────────────────────┐
│ Broker 1 (Leader)                       │
│  └─ 100 partitions                      │
└─────────────────────────────────────────┘
            ↓ (1 thread)
┌─────────────────────────────────────────┐
│ Broker 2 (Follower)                     │
│  └─ Replica 100 partitions               │
└─────────────────────────────────────────┘

Resultado: Demora mais para replicar todas as partições
         → Demora mais para considerar mensagens committed
         → Mensagens não podem ser consumidas até serem committed
         → Maior latência end-to-end
```

### Soluções para Latência com Muitas Partições

#### Opção 1: Limitar Partições por Broker

```bash
# Não defina número arbitrariamente alto de partições
# Calcule baseado na necessidade real

# Exemplo: Em vez de
kafka-topics.sh --create --topic my-topic --partitions 100

# Considere
kafka-topics.sh --create --topic my-topic --partitions 12
```

#### Opção 2: Aumentar Número de Brokers

```
Cluster pequeno: 3 brokers × 100 partitions = ~33 partitions/broker
Cluster maior:   10 brokers × 100 partitions = 10 partitions/broker

Menos partições por broker = Menor latência de replicação
```

#### Opção 3: Aumentar Replica Fetchers (Aplicações Real-Time)

Para aplicações com requisitos de **baixíssima latência** mas que precisam de **muitas partições**:

```properties
# Número de threads fetcher por broker de origem
num.replica.fetchers=1
# Padrão: 1
# Para baixa latência: Aumente se followers não conseguem acompanhar o leader
```

**Como testar:**
1. Comece com o valor padrão (1)
2. Monitore replication lag
3. Aumente gradualmente se necessário

```bash
# Monitore under-replicated partitions
kafka-topics.sh --bootstrap-server localhost:9092 --describe \
  --under-replicated-partitions
```

---

## 🚀 Estratégias de Otimização

### 1. Producer: Batching Mínimo

**Objetivo:** Enviar dados assim que estiverem disponíveis

```properties
linger.ms=0
# Padrão: 0 (JÁ OTIMIZADO!)
# Mantém em 0 para baixa latência
```

#### Como Funciona:

```
linger.ms=0  → Producer envia assim que tem dados
            → Batch pode ter apenas 1 mensagem
            → Latência mínima ⚡

linger.ms=100 → Producer espera 100ms para encher batch
              → Batch maior, mas delay adicional
              → Maior throughput, maior latência
```

**Importante:** Batching **nunca é desabilitado** - mensagens sempre são enviadas em batches, mas com `linger.ms=0` o batch pode conter apenas uma mensagem (a menos que mensagens sejam passadas ao producer mais rápido do que ele pode enviar).

---

### 2. Compressão: Desabilitada

**Trade-off CPU vs Network:**

```properties
compression.type=none
# Padrão: none (JÁ OTIMIZADO!)
# Mantém none para baixa latência
```

#### Análise:

```
COM Compressão:
  ✅ Reduz uso de banda de rede
  ❌ Requer mais ciclos de CPU
  ❌ Adiciona latência de processamento

SEM Compressão:
  ✅ Economiza ciclos de CPU
  ✅ Menor latência
  ❌ Maior uso de banda de rede
```

**Exceção:** Um codec de compressão eficiente (como `lz4`) pode **reduzir latência** em redes lentas, pois menos dados precisam trafegar. Teste no seu ambiente!

---

### 3. Acknowledgments: Mínimos

```properties
acks=1
# Padrão: 1 (JÁ OTIMIZADO!)
# Para latência MUITO baixa: acks=0
```

#### Comparação:

| acks | Comportamento | Latência | Durabilidade |
|------|---------------|----------|--------------|
| **0** | Producer não espera resposta | ⚡ Mínima | ❌ Muito baixa (pode perder sem saber) |
| **1** | Leader responde sem esperar replicas | ⚡ Baixa | ⚠️ Moderada |
| **all/-1** | Leader espera todas replicas in-sync | 🐢 Alta | ✅ Máxima |

**Para latência:** Use `acks=1` (padrão) ou `acks=0` (extremo - não recomendado para dados críticos)

**Importante:** `acks` define quando o **producer** recebe confirmação, não quando a mensagem é considerada **committed** (isso depende de replicação).

---

### 4. Consumer: Fetch Mínimo

**Objetivo:** Buscar dados assim que disponíveis

```properties
fetch.min.bytes=1
# Padrão: 1 (JÁ OTIMIZADO!)
# Mantém em 1 para baixa latência

fetch.max.wait.ms=500
# Padrão: 500ms
# Tempo máximo de espera se fetch.min.bytes não for atingido
```

#### Como Funciona:

Consumer retorna dados quando **qualquer** uma dessas condições é satisfeita:
- ✅ `fetch.min.bytes` de dados disponíveis (1 byte = retorna imediatamente)
- ✅ `fetch.max.wait.ms` expirou

```
fetch.min.bytes=1     → Retorna assim que 1 byte disponível
                      → Latência mínima ⚡

fetch.min.bytes=100KB → Espera 100KB ou timeout
                      → Latência maior, throughput maior
```

**Para latência:** Mantenha `fetch.min.bytes=1` (padrão)

---

### 5. Kafka Streams: Otimizações de Topologia

Para aplicações usando **Kafka Streams** ou **ksqlDB**:

```java
Properties props = new Properties();
props.put(StreamsConfig.TOPOLOGY_OPTIMIZATION_CONFIG, 
          StreamsConfig.OPTIMIZE);
// Padrão: StreamsConfig.NO_OPTIMIZATION
```

#### Benefícios:

- ✅ Reduz reshuffling desnecessário de dados
- ✅ Menos repartition topics intermediários
- ✅ Menor latência de processamento
- ✅ Sem impacto na corretude dos dados

**Exemplo de otimização:**

```
SEM Otimização:
Stream A → [Repartition] → Join → [Repartition] → Output
                   ↓               ↓
              (overhead)      (overhead)

COM Otimização:
Stream A → Join → Output
           ↓
     (otimizado)
```

---

### 6. Stream Processing Local (Joins Rápidos)

**Padrão:** Para lookups de tabelas em grande escala com baixa latência de processamento

#### Problema Tradicional:

```
Application → Query → Remote Database (over network)
                 ↓
            (alta latência por rede)
```

#### Solução Kafka Streams:

```
1. Kafka Connect → Replica Remote DB → Kafka Topic
2. Kafka Streams → Local State Store
3. Application → Local Join (in-memory)
                 ↓
           (latência mínima!)
```

**Benefícios:**
- ✅ Joins locais extremamente rápidos
- ✅ Reduz latência de processamento
- ✅ Reduz carga no banco de dados remoto
- ✅ Estado sempre atualizado via Kafka

**Exemplo:**

```java
KTable<String, User> users = builder.table("users-topic");
KStream<String, Order> orders = builder.stream("orders-topic");

// Join local - sem query a DB remoto!
orders.join(users, (order, user) -> enrichOrder(order, user));
```

---

## 📊 Resumo de Configurações

### Producer

```properties
# Batching mínimo
linger.ms=0
# Padrão: 0 ✅ (já otimizado)

# Sem compressão (ou lz4 se rede lenta)
compression.type=none
# Padrão: none ✅ (já otimizado)

# Acknowledgments mínimos
acks=1
# Padrão: 1 ✅ (já otimizado)
# Extremo: acks=0 (não recomendado)
```

### Consumer

```properties
# Fetch mínimo
fetch.min.bytes=1
# Padrão: 1 ✅ (já otimizado)

# Timeout de fetch
fetch.max.wait.ms=500
# Padrão: 500ms ✅
```

### Broker

```properties
# Replica fetchers (se muitas partições + baixa latência)
num.replica.fetchers=1
# Padrão: 1
# Aumente se followers não acompanham leader
# Exemplo: 2, 4, 8 (teste gradualmente)
```

### Kafka Streams

```java
// Otimizações de topologia
props.put(StreamsConfig.TOPOLOGY_OPTIMIZATION_CONFIG, 
          StreamsConfig.OPTIMIZE);
// Padrão: NO_OPTIMIZATION

// Streams tem producers/consumers embedded
// Aplique também as configs de producer/consumer acima
```

---

## 🧪 Testes de Latência

### End-to-End Latency Test

```bash
# Producer com timestamp
kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic latency-test \
  --producer-property linger.ms=0 \
  --producer-property compression.type=none \
  --producer-property acks=1

# Consumer com timestamp
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic latency-test \
  --from-beginning \
  --property print.timestamp=true
```

### Latency com Verifiable Producer/Consumer

```bash
# Terminal 1: Producer
kafka-verifiable-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic latency-test \
  --max-messages 1000 \
  --throughput 100 \
  --producer.config low-latency.properties

# Terminal 2: Consumer
kafka-verifiable-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic latency-test \
  --group-id latency-test-group
```

**low-latency.properties:**
```properties
linger.ms=0
compression.type=none
acks=1
```

---

## 📈 Métricas para Monitorar

### Producer Latency
```bash
# JMX Metrics
kafka.producer:type=producer-metrics,client-id=*
  - request-latency-avg
  - request-latency-max
  - record-queue-time-avg
```

### Consumer Lag (Indicador de Latência)
```bash
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group seu-grupo \
  --describe

# Observe: LAG column
# LAG alto = Consumer não está acompanhando = Latência end-to-end maior
```

### Broker Metrics
```bash
# Replication lag
kafka.server:type=FetcherLagMetrics,name=ConsumerLag,clientId=*,topic=*,partition=*

# Under-replicated partitions
kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions
```

---

## 🎯 Checklist de Latência

**Para aplicação de baixíssima latência:**

- [ ] Partições: Quantidade equilibrada (não excessiva)
- [ ] `num.replica.fetchers`: Aumentado se necessário
- [ ] Producer `linger.ms=0`
- [ ] Producer `compression.type=none` (ou `lz4` se rede lenta)
- [ ] Producer `acks=1`
- [ ] Consumer `fetch.min.bytes=1`
- [ ] Kafka Streams: `TOPOLOGY_OPTIMIZATION=OPTIMIZE`
- [ ] Monitoramento de latência ativo
- [ ] Testes de latência end-to-end realizados

---

## ⚠️ Trade-offs a Considerar

| Otimização | Ganho | Custo |
|------------|-------|-------|
| `linger.ms=0` | ⚡ Menor latência | 🔻 Menor throughput |
| `acks=1` ou `0` | ⚡ Resposta rápida | ⚠️ Menor durabilidade |
| `compression.type=none` | ⚡ Sem overhead CPU | 📡 Maior uso de rede |
| `fetch.min.bytes=1` | ⚡ Fetch imediato | 🔻 Menor eficiência |
| Menos partições | ⚡ Replicação rápida | 🔻 Menor throughput total |

---

## 💡 Dicas Práticas

1. **Padrões já são bons!** - Maioria das configs já está otimizada para latência
2. **Cuidado com partições** - Mais nem sempre é melhor para latência
3. **Teste acks=1 vs acks=0** - Avalie se a perda de durabilidade é aceitável
4. **Monitore consumer lag** - Indicador chave de latência end-to-end
5. **Use local state stores** - Para joins rápidos em Streams apps
6. **Benchmark no seu ambiente** - Rede, CPU e workload afetam resultados

---

## 🎯 Próximo Passo

Agora que otimizamos para latência, vamos explorar como garantir que o sistema nunca pare:

**Day 4: Otimização para Availability** 🛡️

---

**Low Latency, High Speed! ⚡**
