# Apache Kafka - Otimização para Throughput

## 🎯 Objetivo

Maximizar a **taxa de movimentação de dados** entre producers, brokers e consumers. Para alto throughput, queremos mover o máximo de dados possível dentro de um determinado período de tempo.

## 🔑 Conceito Fundamental

**Partições são a unidade de paralelismo no Kafka**

- Mensagens para diferentes partições podem ser enviadas em **paralelo** por producers
- Escritas em **paralelo** por diferentes brokers
- Leituras em **paralelo** por diferentes consumers

**Regra geral:** Maior número de partições = Maior throughput potencial

## ⚖️ Partições: Quantidade Ideal

### Benefícios de Mais Partições
✅ Maior throughput
✅ Melhor utilização de todos os brokers do cluster
✅ Maior paralelismo de leitura/escrita

### ⚠️ Cuidados ao Aumentar Partições

**Não crie tópicos com número excessivo de partições sem análise!**

Considere:
- **Producer throughput** esperado
- **Consumer throughput** necessário
- **Design dos dados** e distribuição de keys
- **Benchmark** no seu ambiente específico

### Distribuição Equilibrada

Garanta que mensagens sejam distribuídas **uniformemente** entre as partições:
- Evite sobrecarga de algumas partições
- Use key assignment adequado
- Monitore distribuição de carga

```bash
# Verificar distribuição de mensagens por partição
kafka-run-class.sh kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic seu-topico \
  --time -1
```

## 🚀 Estratégias de Otimização

### 1. Batching de Producers

**O passo mais importante para otimizar throughput!**

Producers agrupam múltiplas mensagens indo para a mesma partição e enviam juntas em uma única requisição.

#### Benefícios do Batching:
- ✅ Menos requisições aos brokers
- ✅ Reduz carga dos producers
- ✅ Reduz overhead de CPU nos brokers

#### Configurações Críticas:

```properties
# Aumenta o tamanho máximo em bytes de cada batch
batch.size=100000
# Padrão: 16384 (16KB)
# Recomendado: 100000 - 200000 (100-200KB)

# Tempo de espera para o batch encher antes de enviar
linger.ms=10
# Padrão: 0 (envia imediatamente)
# Recomendado: 10 - 100ms
```

**Trade-off:** Maior latência, pois mensagens não são enviadas assim que ficam prontas.

---

### 2. Compressão

**Envie mais dados usando menos bits!**

#### Configuração:

```properties
compression.type=lz4
# Padrão: none (sem compressão)
# Opções: lz4, snappy, zstd, gzip
```

#### Recomendações:
- ✅ **lz4**: Melhor performance geral (recomendado)
- ✅ **snappy**: Boa alternativa
- ⚠️ **gzip**: Evite - alto uso de CPU
- ✅ **zstd**: Boa taxa de compressão

#### Como Funciona:

1. **Producer** comprime o batch completo
2. **Broker** descomprime para validar
3. **Broker** verifica a compressão configurada no tópico de destino:
   - Se `compression.type=producer` (padrão) → mantém compressão original ✅
   - Se mesma compressão do batch → escreve direto ✅
   - Se compressão diferente (ex: batch em lz4, tópico em gzip) → descomprime e recomprime (impacto!) ⚠️

**Dica:** Mantenha o mesma compressão no producer e no tópico!

#### Eficácia da Compressão

**Compressão é aplicada em batches completos**

→ Mais batching = Melhor taxa de compressão

```
Exemplo visual:
batch.size pequeno  → [msg1|msg2] → compressão: 20%
batch.size grande   → [msg1|msg2|msg3|...|msg10] → compressão: 60%
```

---

### 3. Acknowledgments (acks)

Controla quando o broker responde ao producer que a mensagem foi commitada.

```properties
acks=1
# Padrão: 1
# Opções: 0, 1, all/-1
```

#### Para Throughput Máximo:

**acks=1** (padrão já é otimizado)
- Leader escreve no log local
- Responde **sem esperar** confirmação dos followers
- ⚡ Resposta mais rápida = Maior throughput

**Trade-off:** Menor durabilidade (mensagem pode ser perdida se leader falhar antes de replicar)

---

### 4. Buffer Memory (Producer)

Memória alocada para armazenar mensagens ainda não enviadas.

```properties
buffer.memory=33554432
# Padrão: 33554432 (32MB)
# Ajuste se tiver muitas partições
```

#### Quando Ajustar:
- **Muitas partições** no cluster
- **Mensagens grandes**
- **Linger time alto**

**Objetivo:** Manter pipelines ativos em mais partições → Melhor utilização da banda em mais brokers

Se o limite for atingido:
- Producer bloqueia novos sends
- Até memória liberar ou `max.block.ms` expirar

---

### 5. Fetch Size (Consumer)

Controla quanto dados o consumer obtém em cada fetch do leader broker.

```properties
fetch.min.bytes=100000
# Padrão: 1
# Recomendado: ~100000 (100KB)
```

#### Benefícios:
- ✅ Menos requisições fetch ao broker
- ✅ Reduz overhead de CPU do broker
- ✅ Maior throughput

#### Trade-off:
⚠️ Maior latência - broker só envia quando:
- Fetch acumular `fetch.min.bytes` de dados, OU
- `fetch.max.wait.ms` expirar

```properties
# Tempo máximo de espera para fetch
fetch.max.wait.ms=500
# Padrão: 500ms
```

---

### 6. Consumer Groups e Paralelização

**Use múltiplos consumers em um consumer group!**

```
┌─────────────────────────────────────┐
│ Tópico: 6 partições                 │
└─────────────────────────────────────┘
        ↓       ↓       ↓
    ┌────────────────────────┐
    │   Consumer Group       │
    │  ┌─────┐  ┌─────┐     │
    │  │ C1  │  │ C2  │     │
    │  │ C3  │  │ C4  │     │
    │  │ C5  │  │ C6  │     │
    └──┴─────┴──┴─────┴─────┘
```

#### Benefícios:
- ✅ Processamento paralelo de múltiplas partições
- ✅ Balanceamento de carga entre consumers
- ✅ Maior throughput total

**Limite:** Número de partições do tópico (1 consumer = 1+ partições)

---

### 7. Otimizações Java (Bonus)

#### SSL/TLS Performance

>Use Java 11+ para melhorias de SSL introduzidas no Java 9


#### JVM Garbage Collection

**Minimize GC pause time!**

Pausas longas de GC:
- ❌ Impactam throughput negativamente
- ❌ Podem causar soft failure do broker (ex: timeout de ZooKeeper)

**Recomendação:** Use G1GC ou ZGC

```bash
# Exemplo de configuração JVM
export KAFKA_HEAP_OPTS="-Xms6g -Xmx6g"
export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=20"
```

Consulte: [Deployment Guidelines - JVM GC Tuning](https://docs.confluent.io/platform/current/kafka/deployment.html)

---

## 📊 Resumo de Configurações

### Producer

```properties
# Batching
batch.size=100000
# Padrão: 16384
# Recomendado: 100000 - 200000

linger.ms=10
# Padrão: 0
# Recomendado: 10 - 100

# Compressão
compression.type=lz4
# Padrão: none
# Recomendado: lz4

# Acknowledgments
acks=1
# Padrão: 1
# Para throughput: 1

# Buffer
buffer.memory=33554432
# Padrão: 33554432
# Ajuste se muitas partições
```

### Consumer

```properties
# Fetch size
fetch.min.bytes=100000
# Padrão: 1
# Recomendado: ~100000
```

### Tópico

```bash
# Crie com número adequado de partições
kafka-topics.sh --create \
  --topic high-throughput-topic \
  --partitions 12 \
  --replication-factor 3 \
  --bootstrap-server localhost:9092
```

---

## 🧪 Testes de Performance

### Producer Throughput Test

```bash
kafka-producer-perf-test.sh \
  --topic throughput-test \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props \
    bootstrap.servers=localhost:9092 \
    batch.size=100000 \
    linger.ms=10 \
    compression.type=lz4 \
    acks=1
```

### Consumer Throughput Test

```bash
kafka-consumer-perf-test.sh \
  --topic throughput-test \
  --messages 1000000 \
  --broker-list localhost:9092 \
  --threads 4 \
  --consumer-props \
    fetch.min.bytes=100000
```

---

## 📈 Métricas para Monitorar

### Producer Metrics
- `record-send-rate`: Registros enviados/segundo
- `byte-rate`: Bytes enviados/segundo
- `compression-rate`: Taxa de compressão
- `batch-size-avg`: Tamanho médio dos batches

### Consumer Metrics
- `records-consumed-rate`: Registros consumidos/segundo
- `bytes-consumed-rate`: Bytes consumidos/segundo
- `fetch-size-avg`: Tamanho médio dos fetches
- `fetch-latency-avg`: Latência média dos fetches

### Broker Metrics
- `MessagesInPerSec`: Mensagens recebidas/segundo
- `BytesInPerSec`: Bytes recebidos/segundo
- `BytesOutPerSec`: Bytes enviados/segundo
- Network Handler Idle Percent

---

## ⚠️ Lembretes Importantes

1. **Benchmark sempre!** - Valores dependem do seu ambiente
2. **Trade-off com latência** - Throughput alto geralmente aumenta latência
3. **Trade-off com durabilidade** - `acks=1` sacrifica durabilidade
4. **Distribua uniformemente** - Keys bem distribuídas evitam hotspots
5. **Monitore continuamente** - Ajuste baseado em métricas reais

---

## 🎯 Próximo Passo

Agora que você sabe otimizar para throughput, vamos explorar o outro lado da moeda:

**Day 3: Otimização para Latência** ⚡

---

**Happy High Throughput! 🚀**
