# Apache Kafka - Testes Comparativos: Throughput e Latency

## 🎯 Objetivo

Este guia fornece exemplos práticos para testar e comparar os quatro pilares fundamentais do Kafka usando ferramentas padrão (`kafka-producer-perf-test.sh`, `kafka-consumer-perf-test.sh`) e comandos do Kafka binary. O objetivo é demonstrar como diferentes configurações impactam o comportamento do Kafka e validar os trade-offs entre os objetivos.

## 📋 Pré-requisitos

- Cluster Kafka em execução (local ou remoto)
- Acesso ao diretório `bin` do Kafka (ferramentas de performance)
- Permissões para criar tópicos e executar testes
- Ferramentas de monitoramento (opcional, mas recomendado)

## 🧪 Estrutura dos Testes

Cada seção contém:
1. **Configuração do tópico** - Criação com parâmetros específicos
2. **Teste de performance** - Comandos para executar
3. **Métricas a observar** - O que monitorar
4. **Análise esperada** - Resultados esperados

---

## 1️⃣ Testes de Throughput

### Objetivo
Maximizar a taxa de movimentação de dados (mensagens/segundo, bytes/segundo).

### Configuração: Alta Throughput

```bash
# Criar tópico otimizado para throughput
kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic throughput-high \
  --partitions 12 \
  --replication-factor 3 \
  --config min.insync.replicas=1

# Teste de Producer - Alta Throughput
kafka-producer-perf-test.sh \
  --topic throughput-high \
  --num-records 100000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    batch.size=100000 \
    linger.ms=10 \
    compression.type=lz4 \
    acks=1 \
    buffer.memory=67108864
```

**Métricas Esperadas (depende do hardware):**
- **Records/sec**: 50,000 - 200,000+ 
- **MB/sec**: 50 - 200+ MB/s
- **Avg latency**: 10-50ms

### Configuração: Baixa Throughput (Baseline)

```bash
# Criar tópico com configurações padrão
kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic throughput-low \
  --partitions 3 \
  --replication-factor 1

# Teste de Producer - Configuração Padrão
kafka-producer-perf-test.sh \
  --topic throughput-low \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    batch.size=16384 \
    linger.ms=0 \
    compression.type=none \
    acks=1
```

**Métricas Esperadas (depende do hardware):**
- **Records/sec**: 10,000 - 50,000
- **MB/sec**: 10 - 50 MB/s
- **Avg latency**: 5-20ms


---

## 2️⃣ Testes de Latency

### Objetivo
Minimizar o tempo end-to-end de mensagens (de producer para consumer).

### Configuração: Baixa Latência

```bash
# Criar tópico otimizado para latência
kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic latency-low \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=1

# Teste de Producer - Baixa Latência
kafka-producer-perf-test.sh \
  --topic latency-low \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 10000 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    batch.size=16384 \
    linger.ms=0 \
    compression.type=none \
    acks=1 \
    request.timeout.ms=30000

# Teste de Consumer - Baixa Latência
kafka-consumer-perf-test.sh \                                      
  --bootstrap-server localhost:29092 \
  --topic latency-low \
  --messages 100000 \
  --consumer.config consumer.cofig \
  --print-metrics
```

**Métricas Esperadas (depende do hardware):**
- **Avg latency**: 1-5ms
- **Max latency**: 10-50ms
- **50th percentile**: < 5ms
- **99th percentile**: < 20ms

### Configuração: Alta Latência (Baseline com Batching)

```bash
# Criar tópico
kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic latency-high \
  --partitions 6 \
  --replication-factor 3

# Teste de Producer - Alta Latência (com batching)
kafka-producer-perf-test.sh \
  --topic latency-high \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 10000 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    batch.size=100000 \
    linger.ms=100 \
    compression.type=lz4 \
    acks=all

# Teste de Consumer - Alta Latência
kafka-consumer-perf-test.sh \
  --bootstrap-server localhost:29092 \
  --topic latency-high \
  --messages 100000 \
  --threads 1 
```