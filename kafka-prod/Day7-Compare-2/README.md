# Apache Kafka - Testes Comparativos: Availability e Durability

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

## 3️⃣ Testes de Availability

### Objetivo
Garantir que o sistema continue funcionando mesmo com falhas de brokers.

### Configuração: Alta Disponibilidade

```bash
# Criar tópico com alta disponibilidade
kafka-topics.sh --create \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --topic availability-high \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=1 \
  --config unclean.leader.election.enable=true

# Verificar configuração
kafka-topics.sh --describe \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --topic availability-high
```

### Teste de Falha de Broker

```bash
# Terminal 1: Producer contínuo monitorando
kafka-producer-perf-test.sh \
  --topic availability-high \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput 1000 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    acks=all \
    request.timeout.ms=30000 \
    retries=2147483647

# Terminal 2: Monitorar partições under-replicated
watch -n 1 'kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --under-replicated-partitions | grep availability-high'

# Terminal 3: Monitorar ISR (In-Sync Replicas)
watch -n 1 'kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --topic availability-high'

```

### Configuração: Baixa Disponibilidade (para comparação)

```bash
# Criar tópico com baixa disponibilidade
kafka-topics.sh --create \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --topic availability-low \
  --partitions 6 \
  --replication-factor 1 \
  --config min.insync.replicas=1


```

### Métricas de Availability

```bash
# Verificar partições offline
kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --topic availability-high | grep -i "leader: -1"

# Verificar under-replicated partitions
kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --under-replicated-partitions

# Verificar ISR status
kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --topic availability-high
```

**Métricas Esperadas (depende do Hardware):**
- **Tempo de detecção de falha**: < 10 segundos
- **Tempo de eleição de leader**: < 5 segundos
- **Producer downtime**: 0 segundos (com min.insync.replicas=1)
- **Under-replicated partitions**: Temporário durante recovery

---

## 4️⃣ Testes de Durability

### Objetivo
Garantir que mensagens committed nunca sejam perdidas.

### Configuração: Alta Durabilidade

```bash
# Criar tópico com alta durabilidade
kafka-topics.sh --create \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --topic durability-high \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=2 \
  --config unclean.leader.election.enable=false

# Teste de Producer - Alta Durabilidade
kafka-producer-perf-test.sh \
  --topic durability-high \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 5000 \
  --producer-props \
    bootstrap.servers=localhost:29092 \
    acks=all \
    enable.idempotence=true \
    max.in.flight.requests.per.connection=5 \
    retries=2147483647 \
    request.timeout.ms=30000
```

**Métricas Esperadas (depende do Hardware):**
- **Records/sec**: Menor que configuração de throughput (trade-off)
- **Latency**: Maior que configuração de baixa latência
- **Zero perda de mensagens**: Mesmo com falhas

### Teste

```bash
# Terminal 1: Producer com contagem de mensagens
for i in {1..20}; do
  echo "message-$i" | kafka-console-producer.sh \
    --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
    --topic durability-high \
    --producer-property acks=all
  echo "Sent message $i"
done

# Terminal 2: Consumer contando mensagens recebidas
kafka-console-consumer.sh \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --topic durability-high \
  --from-beginning \
  --max-messages 20 | wc -l

```

---


## Tabela Comparativa de Resultados ( Exemplo)

Use esta tabela para documentar seus resultados:

| Configuração | Records/sec | MB/sec | Avg Latency | Max Latency | Durability | Availability |
|-------------|-------------|--------|-------------|-------------|------------|--------------|
| **High Throughput** | | | | | ⚠️ Média | ✅ Alta |
| **Low Throughput** | | | | | ✅ Alta | ✅ Alta |
| **Low Latency** | | | | | ⚠️ Média | ✅ Alta |
| **High Latency** | | | | | ✅ Alta | ✅ Alta |
| **High Availability** | | | | | ⚠️ Média | ✅ Máxima |
| **Low Availability** | | | | | ❌ Baixa | ❌ Baixa |
| **High Durability** | | | | | ✅ Máxima | ⚠️ Média |
| **Low Durability** | | | | | ❌ Baixa | ✅ Alta |

---

## Comandos

### Monitorar Métricas em Tempo Real

```bash
# Monitorar throughput de producer
kafka-run-class.sh kafka.tools.ConsumerPerformance \
  --broker-list localhost:29092 \
  --topic seu-topico \
  --messages 1000000 \
  --threads 1 \
  --show-detailed-stats

# Verificar lag de consumer
kafka-consumer-groups.sh \
  --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --group seu-grupo \
  --describe

# Monitorar partições
kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --topic seu-topico

# Verificar under-replicated partitions
kafka-topics.sh --bootstrap-server localhost:29092,localhost:39092,localhost:49092 \
  --describe --under-replicated-partitions

```

---

## Análise e Interpretação de Resultados

### Como Interpretar os Resultados

#### Throughput
- **Records/sec alto**: Sistema processando muitos eventos
- **MB/sec alto**: Sistema movendo grandes volumes de dados
- **Trade-off**: Geralmente aumenta latência

#### Latency
- **Avg latency baixo**: Mensagens processadas rapidamente
- **99th percentile**: Latência de pico (importante para SLAs)
- **Trade-off**: Geralmente reduz throughput

#### Availability
- **Zero downtime durante falhas**: Alta disponibilidade
- **Tempo de recovery rápido**: Sistema resiliente
- **Trade-off**: Pode comprometer durabilidade

#### Durability
- **Zero perda de mensagens**: Alta durabilidade
- **Mensagens committed garantidas**: Dados seguros
- **Trade-off**: Geralmente reduz throughput e disponibilidade

### Padrões Esperados

1. **Throughput ↑ → Latency ↑**: Batching aumenta throughput mas adiciona latência
2. **Durability ↑ → Throughput ↓**: acks=all reduz throughput
3. **Availability ↑ → Durability ↓**: unclean leader election pode perder dados
4. **Latency ↓ → Throughput ↓**: Sem batching reduz throughput


## 🎯 Conclusão

Este guia fornece uma base sólida para testar e comparar os quatro pilares fundamentais do Kafka. Lembre-se:

1. **Benchmark sempre**: Resultados variam com hardware, rede e workload
2. **Entenda os trade-offs**: Não é possível maximizar tudo simultaneamente
3. **Configure por caso de uso**: Diferentes tópicos podem ter diferentes objetivos
4. **Monitore continuamente**: Métricas mudam com o tempo e carga
5. **Teste em staging**: Sempre valide antes de produção

---

## 📚 Recursos Adicionais

- [Apache Kafka Performance Tuning](https://kafka.apache.org/documentation/#performance)
- [Kafka Producer Performance](https://kafka.apache.org/documentation/#producerconfigs)
- [Kafka Consumer Performance](https://kafka.apache.org/documentation/#consumerconfigs)
- [Confluent Performance Testing](https://docs.confluent.io/platform/current/kafka/deployment.html#performance)

---

**Bons testes e boa produção com Apache Kafka! 🚀**