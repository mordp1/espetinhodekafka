# Apache Kafka - Otimização para Durability

## 🎯 Objetivo

Garantir que **nenhuma mensagem seja perdida** em caso de falhas. Para alta durabilidade, queremos que os dados sejam persistidos de forma confiável e replicados adequadamente antes de serem considerados "committed".

## 🔑 Conceito Fundamental

**Alta Durabilidade = Zero Perda de Dados**

O Kafka é projetado para ser durável por padrão, mas você pode aumentar ainda mais as garantias de durabilidade com configurações apropriadas. Otimizar para durability significa:
- ✅ Garantir replicação completa antes de confirmar escrita
- ✅ Prevenir perda de dados em caso de falhas de broker
- ✅ Garantir que mensagens committed nunca sejam perdidas
- ✅ Proteger contra corrupção de dados

## ⚖️ Trade-off Principal: Durability vs Availability & Performance

```
Alta Durability              Alta Availability/Performance
     ↓                                ↓
Espera replicação           vs    Confirma rapidamente
   completa                          com menos réplicas
     ↓                                ↓
Sem perda de dados              Recuperação rápida
Performance menor               Pode perder dados
```

**Você precisa decidir:** Quão críticos são seus dados?

---

## 🚀 Estratégias de Otimização

### 1. Replication Factor: Redundância de Dados

**A configuração mais importante para durabilidade!**

```properties
replication.factor=3
# Padrão: 1 (não recomendado para produção!)
# Para ALTA DURABILIDADE: 3 ou mais
# Mínimo recomendado em produção: 3
```

#### Como Funciona:

```
replication.factor=1:
  ❌ Sem redundância
  ❌ Se broker falhar → PERDA DE DADOS
  ❌ NÃO use em produção!

replication.factor=2:
  ⚠️ 1 cópia de backup
  ⚠️ Tolera falha de 1 broker
  ⚠️ Mínimo aceitável (mas ainda arriscado)

replication.factor=3:
  ✅ 2 cópias de backup
  ✅ Tolera falha de 2 brokers
  ✅ RECOMENDADO para produção
  ✅ Equilíbrio entre durabilidade e custo

replication.factor=3+:
  ✅ Alta redundância
  ⚠️ Maior custo de armazenamento
  ⚠️ Maior overhead de replicação
  ✅ Para dados extremamente críticos
```

#### Exemplo de Criação de Tópico:

```bash
# ❌ Não faça isso em produção
kafka-topics.sh --create --topic my-topic \
  --partitions 3 --replication-factor 1

# ✅ Recomendado para produção
kafka-topics.sh --create --topic my-topic \
  --partitions 3 --replication-factor 3

# ✅ Para dados críticos (ex: transações financeiras)
kafka-topics.sh --create --topic financial-transactions \
  --partitions 3 --replication-factor 5
```

**Regra de Ouro:** `replication.factor >= 3` em produção

---

### 2. Producer Acknowledgments: Esperar Todas as Réplicas

**Garantir que dados sejam replicados antes de confirmar**

```properties
acks=all  # ou acks=-1 (são equivalentes)
# Padrão: 1 (não é o mais durável!)
# Para ALTA DURABILIDADE: all
```

#### Comparação Detalhada:

| acks | O que espera | Durabilidade | Latência | Uso |
|------|-------------|--------------|----------|-----|
| **0** | Nada (fire & forget) | ❌ Muito baixa | ⚡ Mínima | Métricas, logs não críticos |
| **1** | Apenas leader | ⚠️ Moderada | 🔶 Baixa | Casos balanceados |
| **all/-1** | Leader + ISR completo | ✅ Máxima | 🐢 Alta | Dados críticos |

#### Cenário de Falha:

```
acks=1 (Leader confirma sozinho):
  1. Producer → Leader escreve
  2. Leader → confirma producer ✅
  3. 💥 Leader FALHA antes de replicar
  4. Followers não têm os dados
  5. ❌ DADOS PERDIDOS

acks=all (Espera replicação):
  1. Producer → Leader escreve
  2. Leader → Replica para followers
  3. Followers → confirmam leader
  4. Leader → confirma producer ✅
  5. 💥 Leader FALHA
  6. ✅ Followers têm os dados
  7. ✅ SEM PERDA
```

**Para Durabilidade:** `acks=all`

---

### 3. Min In-Sync Replicas: Garantir Replicação Mínima

**Trabalha em conjunto com `acks=all`**

```properties
min.insync.replicas=2
# Padrão: 1 (não é o mais seguro!)
# Para ALTA DURABILIDADE: 2 (com replication.factor=3)
# Regra: min.insync.replicas < replication.factor
```

#### Como Funciona:

`min.insync.replicas` define quantas réplicas **in-sync** (atualizadas) devem confirmar uma escrita quando `acks=all`.

```
Cenário: replication.factor=3, acks=all

min.insync.replicas=1:
  ⚠️ Apenas 1 réplica precisa estar in-sync
  ⚠️ Se 2 followers falharem, leader sozinho confirma
  ⚠️ BAIXA durabilidade (apesar de acks=all!)

min.insync.replicas=2:
  ✅ 2 réplicas devem estar in-sync
  ✅ Leader + pelo menos 1 follower confirmam
  ✅ Tolera falha de 1 réplica
  ✅ ALTA durabilidade

min.insync.replicas=3:
  ✅ Todas 3 réplicas devem estar in-sync
  ❌ Se 1 broker falhar → Producer recebe erro
  ❌ Disponibilidade comprometida
  ⚠️ Muito restritivo
```

#### Configuração Recomendada:

```bash
# Combinação ideal para durabilidade com disponibilidade razoável
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name critical-topic \
  --alter --add-config min.insync.replicas=2

# Verificar configuração
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name critical-topic \
  --describe
```

**Fórmula:** `min.insync.replicas = replication.factor - 1`
- replication.factor=3 → min.insync.replicas=2 ✅
- replication.factor=5 → min.insync.replicas=3 ✅

---

### 4. Unclean Leader Election: Prevenir Perda de Dados

**NUNCA permita líderes "sujos" em ambientes críticos**

```properties
unclean.leader.election.enable=false
# Padrão: false (JÁ OTIMIZADO!)
# Para ALTA DURABILIDADE: false (manter padrão)
```

#### O que são "Unclean Leaders"?

```
Broker 1 (Leader, ISR)    → [msg1, msg2, msg3, msg4, msg5] → 💥 FALHOU
Broker 2 (Follower, ISR)  → [msg1, msg2, msg3, msg4] → Atrasado
Broker 3 (Follower)       → [msg1, msg2] → FORA do ISR

unclean=false (DURABILIDADE):
  → Apenas Broker 2 pode ser eleito (está no ISR)
  → Broker 3 NÃO pode ser eleito (fora do ISR)
  → ✅ SEM perda de dados (msg4, msg5 preservadas)
  → ⚠️ Se ISR vazio → partição fica offline

unclean=true (DISPONIBILIDADE):
  → Broker 3 PODE ser eleito
  → ❌ msg3, msg4, msg5 PERDIDAS
  → ✅ Partição volta rapidamente
```

#### Decisão:

```
Dados Críticos (financeiro, transacional):
  unclean.leader.election.enable=false ✅
  → Aceita downtime para não perder dados

Dados Não-Críticos (logs, métricas):
  unclean.leader.election.enable=true
  → Prioriza disponibilidade sobre durabilidade
```

**Para Durabilidade:** `unclean.leader.election.enable=false` (padrão)

---

### 5. Log Flush: Força Flush para Disco

**⚠️ Geralmente NÃO recomendado alterar!**

```properties
# Padrão: Sistema operacional decide (mais eficiente)
# Para EXTREMA durabilidade: Forçar flush
```

#### Como Funciona o Flush:

```
Escrita Normal (padrão):
  1. Kafka escreve → Page Cache do OS
  2. OS decide quando flush → Disco físico
  3. ✅ Muito mais rápido (menos I/O)
  4. ⚠️ Pode perder dados se server crash físico

Flush Forçado:
  1. Kafka escreve → Page Cache do OS
  2. Kafka força → Flush imediato para disco
  3. ❌ Performance impacto significativo
  4. ✅ Durabilidade máxima (mesmo em crash)
```

#### Configurações de Flush:

```properties
# Por número de mensagens
log.flush.interval.messages=10000
# Força flush a cada 10000 mensagens

# Por tempo
log.flush.interval.ms=1000
# Força flush a cada 1 segundo
```

#### ⚠️ Recomendação do Kafka:

**NÃO configure flush manual!**

Motivos:
- ✅ Replicação já garante durabilidade (melhor que flush local)
- ✅ Page cache do OS é muito eficiente
- ❌ Flush forçado degrada performance drasticamente
- ✅ Com `replication.factor=3` + `acks=all`, dados estão em múltiplos brokers

```
Melhor Estratégia:
  replication.factor=3
  + acks=all
  + min.insync.replicas=2
  >> MUITO MELHOR que flush forçado!
```

**Para Durabilidade:** Confie na replicação, não force flush

---

### 6. Producer Retries: Retentar em Caso de Falhas

**Garantir que mensagens não sejam perdidas devido a falhas temporárias**

```properties
retries=2147483647  # Integer.MAX_VALUE
# Padrão: 2147483647 (JÁ OTIMIZADO!)
# Mantém valor alto para durabilidade

delivery.timeout.ms=120000  # 2 minutos
# Padrão: 120000ms
# Tempo total para tentar entregar mensagem
```

#### Como Funcionam:

```
Producer tenta enviar mensagem:

Falha transitória (ex: líder temporariamente indisponível):
  1. Producer recebe erro
  2. Retry automático (até retries vezes)
  3. ✅ Mensagem eventualmente é entregue
  4. ✅ SEM perda de dados

Falha permanente (após todas tentativas):
  1. Producer recebe exceção final
  2. ❌ Aplicação deve tratar
  3. ⚠️ Mensagem pode ser perdida se app não tratar
```

#### Configuração com Idempotência:

```properties
# Melhor prática moderna
enable.idempotence=true
# Padrão: true (Kafka 3.0+)
# Previne duplicatas em retries

# Com idempotência:
# - acks=all (forçado)
# - retries=MAX (forçado)
# - max.in.flight.requests.per.connection=5
```

**Idempotência:**
- ✅ Garante exactly-once por partition
- ✅ Previne duplicatas em retries
- ✅ SEM overhead de performance significativo
- ✅ Deve estar sempre habilitado

**Para Durabilidade:** `enable.idempotence=true` (padrão moderno)

---

### 7. Consumer Offset Commits: Não Perder Progresso

**Garantir que consumer não reprocesse ou pule mensagens**

```properties
enable.auto.commit=false
# Para controle manual e durabilidade máxima
```

#### Padrões de Commit:

**Opção 1: Auto-commit (Padrão)**
```java
// Configuração
props.put("enable.auto.commit", "true");
props.put("auto.commit.interval.ms", "5000");

// Risco: Mensagem pode ser committed antes de processar
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        // Se falhar aqui, offset já foi committed
        processRecord(record); // ❌ Pode perder mensagem
    }
}
```

**Opção 2: Commit Manual Após Processamento (Recomendado)**
```java
// Configuração
props.put("enable.auto.commit", "false");

while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        processRecord(record); // Processa primeiro
        consumer.commitSync(); // ✅ Commit somente após sucesso
    }
}
```

**Opção 3: Transacional (Máxima Durabilidade)**
```java
// Para exactly-once entre Kafka e sistema externo
props.put("isolation.level", "read_committed");

// Producer transacional
producer.initTransactions();
try {
    producer.beginTransaction();
    // Processa e produz
    producer.send(new ProducerRecord<>("output-topic", result));
    // Commit offsets dentro da transação
    producer.sendOffsetsToTransaction(offsets, consumerGroupId);
    producer.commitTransaction();
} catch (Exception e) {
    producer.abortTransaction();
}
```

**Para Durabilidade:** Commit manual após processamento bem-sucedido

---

## 📋 Checklist de Configuração para Alta Durabilidade

### Producer:
```properties
# ✅ Esperar todas réplicas
acks=all

# ✅ Idempotência (previne duplicatas)
enable.idempotence=true

# ✅ Retries (já otimizado por padrão)
retries=2147483647
delivery.timeout.ms=120000

# ✅ Compressão (opcional, economiza espaço)
compression.type=lz4
```

### Broker/Topic:
```properties
# ✅ Replicação adequada
replication.factor=3

# ✅ Mínimo de réplicas in-sync
min.insync.replicas=2

# ✅ Prevenir líderes sujos
unclean.leader.election.enable=false

# ✅ Retenção adequada
log.retention.hours=168  # 7 dias
log.retention.bytes=-1   # Sem limite de tamanho
```

### Consumer:
```properties
# ✅ Commit manual
enable.auto.commit=false

# ✅ Isolation level (para transações)
isolation.level=read_committed
```

---

## 🎭 Comparação: Configurations vs Requirements

| Caso de Uso | Replication Factor | acks | min.insync.replicas | unclean.leader |
|-------------|-------------------|------|---------------------|----------------|
| **Logs não-críticos** | 1-2 | 1 | 1 | true |
| **Eventos gerais** | 3 | 1 | 1 | false |
| **Dados importantes** | 3 | all | 2 | false |
| **Transações financeiras** | 5 | all | 3 | false |
| **Regulatório/Compliance** | 5 | all | 4 | false |

---

## 🔬 Testando Durabilidade

### 1. Simular Falha de Broker

```bash
# Terminal 1: Producer com acks=all
kafka-console-producer --bootstrap-server localhost:9092 \
  --topic test-durability \
  --producer-property acks=all

# Terminal 2: Matar broker (simular falha)
docker stop kafka-broker-1

# Terminal 1: Observar comportamento
# - acks=all → Producer bloqueia ou retorna erro
# - acks=1 → Producer continua (mas pode perder dados)
```

### 2. Verificar Under-Replicated Partitions

```bash
# Partições com replicação incompleta
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions

# Deve retornar vazio em cluster saudável
```

### 3. Monitorar ISR

```bash
# Verificar quais replicas estão in-sync
kafka-topics.sh --bootstrap-server localhost:9092 \
  --topic test-durability --describe

# Verificar campo "Isr" (deve conter todas replicas)
```

### 4. Teste de Crash Recovery

```bash
# 1. Enviar mensagens
seq 1 1000 | kafka-console-producer --topic test --bootstrap-server localhost:9092

# 2. Kill broker abruptamente
kill -9 <broker-pid>

# 3. Reiniciar broker
# 4. Verificar se todas mensagens foram preservadas
kafka-console-consumer --topic test --from-beginning --bootstrap-server localhost:9092
```

---

## 📊 Monitoramento de Durabilidade

### Métricas Importantes:

```bash
# JMX Metrics via JConsole ou Prometheus

# Under-replicated partitions (deve ser 0)
kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions

# Offline partitions (deve ser 0)
kafka.controller:type=KafkaController,name=OfflinePartitionsCount

# Leader election rate (baixo é melhor)
kafka.controller:type=ControllerStats,name=LeaderElectionRateAndTimeMs

# ISR shrinks (deve ser 0 ou raro)
kafka.server:type=ReplicaManager,name=IsrShrinksPerSec

# ISR expands (deve ser 0 ou raro)
kafka.server:type=ReplicaManager,name=IsrExpandsPerSec
```

---

## ⚡ Performance vs Durability

### Trade-offs:

```
Configuração                  Performance    Durability
──────────────────────────────────────────────────────
replication.factor=1          ⚡⚡⚡           ❌
replication.factor=3          ⚡⚡             ✅✅
replication.factor=5          ⚡               ✅✅✅

acks=0                        ⚡⚡⚡           ❌
acks=1                        ⚡⚡             ⚠️
acks=all                      ⚡               ✅✅✅

min.insync.replicas=1         ⚡⚡⚡           ⚠️
min.insync.replicas=2         ⚡⚡             ✅✅
min.insync.replicas=3         ⚡               ✅✅✅

unclean.leader=true           ⚡⚡⚡           ❌
unclean.leader=false          ⚡⚡             ✅✅✅
```

### Configuração Balanceada (Recomendada):

```properties
# Producer
acks=all
enable.idempotence=true
compression.type=lz4

# Topic
replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false

# Resultado:
# - ✅ Alta durabilidade (tolerates 1 broker failure)
# - ✅ Performance razoável (2/3 replicas confirmam)
# - ✅ Disponibilidade razoável (permite 1 falha)
```

---

## 🎯 Resumo: Configuração para Máxima Durabilidade

```bash
# 1. Criar tópico com replicação
kafka-topics.sh --create --topic critical-data \
  --bootstrap-server localhost:9092 \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=2 \
  --config unclean.leader.election.enable=false

# 2. Producer configuration
cat > producer.properties <<EOF
acks=all
enable.idempotence=true
retries=2147483647
delivery.timeout.ms=120000
compression.type=lz4
EOF

# 3. Consumer configuration
cat > consumer.properties <<EOF
enable.auto.commit=false
isolation.level=read_committed
EOF

# 4. Produzir com configurações
kafka-console-producer --bootstrap-server localhost:9092 \
  --topic critical-data \
  --producer.config producer.properties

# 5. Consumir com configurações
kafka-console-consumer --bootstrap-server localhost:9092 \
  --topic critical-data \
  --consumer.config consumer.properties \
  --from-beginning
```

---

## 🔐 Bônus: Durabilidade + Segurança

Para ambientes regulados (financeiro, saúde, etc.):

```properties
# Encriptação em trânsito
security.protocol=SSL
ssl.endpoint.identification.algorithm=https

# Encriptação em repouso (disco)
# Configurar no OS level ou usar cloud provider encryption

# Auditoria
log.message.timestamp.type=LogAppendTime
log.retention.hours=2160  # 90 dias (compliance)

# Quotas (prevenir DoS)
quota.producer.default=10485760  # 10MB/s
quota.consumer.default=20971520  # 20MB/s
```

---

## 📚 Leitura Adicional

- [Kafka Data Reliability](https://kafka.apache.org/documentation/#replication)
- [Producer Configurations](https://kafka.apache.org/documentation/#producerconfigs)
- [Broker Configurations](https://kafka.apache.org/documentation/#brokerconfigs)
- [Kafka Replication Internals](https://kafka.apache.org/documentation/#replication)

---

## 🎬 Conclusão

**Para garantir durabilidade em Kafka:**

1. ✅ Use `replication.factor=3` (mínimo produção)
2. ✅ Configure `acks=all` no producer
3. ✅ Defina `min.insync.replicas=2` nos tópicos críticos
4. ✅ Mantenha `unclean.leader.election.enable=false`
5. ✅ Habilite `enable.idempotence=true` no producer
6. ✅ Use commit manual de offsets no consumer
7. ✅ Monitore under-replicated partitions e ISR

**Lembre-se:** Durabilidade tem custo de performance e disponibilidade. Configure baseado na criticidade dos seus dados! 🎯
