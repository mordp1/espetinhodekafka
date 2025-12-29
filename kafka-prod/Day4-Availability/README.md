# Apache Kafka - Otimização para Availability

## 🎯 Objetivo

Minimizar **downtime** e **tempo de recuperação** em caso de falhas. Para alta disponibilidade, queremos que o Kafka se recupere o mais rápido possível de cenários de falha.

## 🔑 Conceito Fundamental

**Alta Disponibilidade = Recuperação Rápida de Falhas**

O Kafka é um sistema distribuído projetado para tolerar falhas. Otimizar para availability significa:
- ✅ Detectar falhas rapidamente
- ✅ Eleger novos leaders rapidamente
- ✅ Rebalancear consumers rapidamente
- ✅ Restaurar estado rapidamente

## ⚖️ Trade-off Principal: Availability vs Durability

```
Alta Availability          Alta Durability
     ↓                           ↓
Aceita líderes         vs    Apenas líderes
   "sujos"                    do ISR
     ↓                           ↓
Recuperação rápida         Sem perda de dados
Pode perder dados          Recuperação mais lenta
```

**Você precisa decidir:** O que é mais importante para seu caso de uso?

---

## 🚀 Estratégias de Otimização

### 1. Partições: Quantidade Balanceada

**Problema:** Mais partições aumentam paralelismo, MAS também aumentam tempo de recuperação.

```
Cenário de Falha de Broker:

3 partições    → 3 eleições de leader  → Recuperação rápida ✅
1000 partições → 1000 eleições de leader → Recuperação lenta ❌

Durante eleições de leader:
  ❌ Todas requisições de produce PAUSAM
  ❌ Todas requisições de consume PAUSAM
```

**Eleições acontecem POR PARTIÇÃO!**

### Recomendações:

```bash
# ❌ Evite criar tópicos com partições excessivas
kafka-topics.sh --create --topic my-topic --partitions 1000

# ✅ Calcule baseado em necessidade real
kafka-topics.sh --create --topic my-topic --partitions 12

# Considere:
# - Throughput necessário
# - Paralelismo de consumers
# - TEMPO DE RECOVERY em caso de falha
```

---

### 2. Min In-Sync Replicas: Tolerância a Falhas

**Aplicável quando:** Producer usa `acks=all` (ou `acks=-1`)

```properties
min.insync.replicas=1
# Padrão: 1
# Para ALTA DISPONIBILIDADE: 1
# Para ALTA DURABILIDADE: 2 ou mais
```

#### Como Funciona:

`min.insync.replicas` define o número **mínimo** de réplicas que devem confirmar uma escrita para ser considerada bem-sucedida.

```
Cenário: Tópico com replication.factor=3

min.insync.replicas=1:
  - Tolera falha de 2 replicas
  - Producer continua funcionando ✅
  - ALTA DISPONIBILIDADE

min.insync.replicas=2:
  - Tolera falha de 1 replica
  - Producer falha se 2+ replicas caírem ⚠️
  - EQUILÍBRIO

min.insync.replicas=3:
  - Não tolera falhas
  - Producer falha se qualquer replica cair ❌
  - ALTA DURABILIDADE, BAIXA DISPONIBILIDADE
```

#### ISR (In-Sync Replicas) em Redução:

```
Cenário: ISR está diminuindo devido a falhas

min.insync.replicas ALTO → Mais provável producer exception
                         → MENOR disponibilidade ❌

min.insync.replicas BAIXO → Tolera mais falhas de replicas
                          → MAIOR disponibilidade ✅
```

**Para Alta Disponibilidade:** `min.insync.replicas=1`

---

### 3. Unclean Leader Election: Recuperação Rápida

**A configuração mais controversa!**

```properties
unclean.leader.election.enable=true
# Padrão: false (para durabilidade)
# Para ALTA DISPONIBILIDADE: true
# Topic override disponível
```

#### O Dilema:

```
Falha de Broker → Eleição de novo Leader

unclean.leader.election.enable=false (PADRÃO):
  ✅ Apenas brokers do ISR podem ser eleitos
  ✅ SEM perda de mensagens committed
  ❌ Se ISR vazio → Partição INDISPONÍVEL até broker voltar
  ❌ Maior downtime

unclean.leader.election.enable=true:
  ✅ Brokers FORA do ISR podem ser eleitos
  ✅ Eleição RÁPIDA
  ✅ Partição volta rapidamente
  ✅ MENOR downtime
  ❌ PODE PERDER mensagens committed mas não replicadas
```

#### Exemplo Visual:

```
Broker 1 (Leader, ISR)    → [msg1, msg2, msg3, msg4, msg5] → 💥 FALHOU
Broker 2 (Follower, ISR)  → [msg1, msg2, msg3] → Atrasado, caiu do ISR
Broker 3 (Follower)       → [msg1, msg2] → MUITO atrasado, fora do ISR

unclean=false:
  → Espera Broker 1 ou 2 voltar
  → Partição OFFLINE ❌
  → Downtime prolongado

unclean=true:
  → Elege Broker 3 imediatamente
  → Partição ONLINE ✅
  → msg3, msg4, msg5 PERDIDAS ⚠️
```

**Para Alta Disponibilidade:** `unclean.leader.election.enable=true`

**⚠️ CUIDADO:** Use apenas se puder tolerar perda de dados!

---

### 4. Recovery Threads: Startup Rápido

**Acelera o processo de log recovery no startup do broker**

```properties
num.recovery.threads.per.data.dir=1
# Padrão: 1
# Para startup rápido: número de discos em log.dirs
```

#### O que é Log Recovery?

Quando um broker inicia:
1. Escaneia todos os arquivos de log
2. Reconstrói índices
3. Prepara para sincronizar com outros brokers

```
Broker com milhares de log segments:
  → Muitos arquivos de índice
  → Processo de loading LENTO
  → Demora para ficar disponível
```

#### Otimização com RAID:

Se você usa **RAID** (alta performance + tolerância a falhas):

```properties
# Exemplo: RAID com 8 discos
num.recovery.threads.per.data.dir=8

# Resultado:
# - Paraleliza loading de logs
# - Reduz tempo de startup
# - Broker fica disponível mais rápido
```

**Cálculo:**
```bash
# Conte os diretórios em log.dirs
log.dirs=/data/kafka-logs-1,/data/kafka-logs-2,/data/kafka-logs-3

# Se 3 diretórios:
num.recovery.threads.per.data.dir=3
```

---

### 5. Consumer Session Timeout: Detecção Rápida de Falhas

**Detecta falhas de consumer o mais rápido possível**

```properties
session.timeout.ms=10000
# Padrão: 10000 (10 segundos)
# Para detecção rápida: tão baixo quanto viável
# Exemplo: 6000 (6 segundos)
```

#### Como Funciona:

Consumers mantêm liveness através de **heartbeats** (thread em background desde KIP-62).

```
Consumer envia heartbeats → Broker recebe
                          ↓
           Se não receber em session.timeout.ms:
                          ↓
              Consumer considerado MORTO
                          ↓
              Rebalance automático
```

#### Tipos de Falhas:

```
Hard Failure (SIGKILL):
  → Consumer para abruptamente
  → Heartbeat para
  → Detectado em session.timeout.ms

Soft Failure (timeout):
  → poll() demora demais
  → JVM GC pause longo
  → Heartbeat para temporariamente
```

#### Trade-off:

```
session.timeout.ms BAIXO:
  ✅ Detecta falhas RÁPIDO
  ✅ Rebalance RÁPIDO
  ✅ MAIOR disponibilidade
  ❌ Soft failures indesejados (false positives)

session.timeout.ms ALTO:
  ✅ Tolera GC pauses
  ✅ Tolera processamento lento
  ❌ Demora para detectar falhas REAIS
  ❌ MENOR disponibilidade
```

**Recomendação:** Configure o mais baixo possível sem causar soft failures.

#### Evitando Soft Failures:

**Problema 1:** `poll()` demora muito processando mensagens

```properties
# Solução A: Aumenta tempo máximo entre polls
max.poll.interval.ms=300000
# Padrão: 300000 (5 minutos)

# Solução B: Reduz número de mensagens por poll
max.poll.records=500
# Padrão: 500
# Reduzir: 100, 200
```

**Problema 2:** JVM GC pause longo

```bash
# Otimize JVM GC
export KAFKA_HEAP_OPTS="-Xms4g -Xmx4g"
export KAFKA_JVM_PERFORMANCE_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=20"
```

---

### 6. Standby Replicas (Kafka Streams): Restauração Rápida

**Acelera restauração de estado quando tasks são rebalanceadas**

```properties
num.standby.replicas=0
# Padrão: 0 (sem standbys)
# Para restauração rápida: 1 ou mais
```

#### Como Funciona:

Quando **Kafka Streams** rebalanceia workloads entre instâncias:

```
SEM Standby Replicas (num.standby.replicas=0):
  1. Task movida para nova instância
  2. State store NÃO existe localmente
  3. Replay changelog do INÍCIO
  4. ❌ DEMORA MUITO (muitos GB de dados)
  5. Aplicação fica indisponível durante restauração

COM Standby Replicas (num.standby.replicas=1):
  1. Task movida para nova instância
  2. State store JÁ EXISTE localmente (standby mantido atualizado)
  3. Replay changelog do último checkpoint
  4. ✅ RÁPIDO (apenas delta)
  5. Aplicação volta rapidamente
```

#### Exemplo Visual:

```
Instância 1 (Primary Task A)     Instância 2 (Standby Task A)
     ↓                                  ↓
[State Store A]                   [State Store A - replica]
     ↓                                  ↓
Processando mensagens            Mantém state atualizado (standby)

💥 Instância 1 falha!

Instância 2 assume Task A:
  → State store JÁ está 95% atualizado
  → Apenas replay últimos 5% do changelog
  → RESTAURAÇÃO RÁPIDA ⚡
```

**Trade-off:**
- ✅ Restauração muito mais rápida
- ❌ Usa mais recursos (CPU, memória, disco)
- ❌ Mais tráfego de rede

**Para Alta Disponibilidade:** `num.standby.replicas=1` ou mais

---

## 📊 Resumo de Configurações

### Consumer

```properties
# Session timeout - tão baixo quanto viável
session.timeout.ms=10000
# Padrão: 10000 (10s)
# Recomendado: 6000-8000 (6-8s)
# ⚠️ Não muito baixo para evitar soft failures

# Se poll() demora muito
max.poll.interval.ms=300000
# Padrão: 300000 (5min)

max.poll.records=500
# Padrão: 500
# Reduzir se necessário
```

### Broker

```properties
# Unclean leader election - CUIDADO!
unclean.leader.election.enable=true
# Padrão: false
# Para ALTA DISPONIBILIDADE: true
# ⚠️ Pode perder dados!
# Topic override disponível

# Min in-sync replicas
min.insync.replicas=1
# Padrão: 1 ✅
# Para ALTA DISPONIBILIDADE: 1
# Topic override disponível

# Recovery threads
num.recovery.threads.per.data.dir=1
# Padrão: 1
# Recomendado: número de diretórios em log.dirs
```

### Kafka Streams

```properties
# Standby replicas
num.standby.replicas=1
# Padrão: 0
# Para restauração rápida: 1 ou mais

# Streams tem producers/consumers embedded
# Aplique também as configs de consumer acima
```

---

## 🧪 Testes de Availability

### Simular Falha de Broker

```bash
# Terminal 1: Criar tópico com replicação
kafka-topics.sh --create \
  --topic ha-test \
  --partitions 3 \
  --replication-factor 3 \
  --config min.insync.replicas=1 \
  --bootstrap-server localhost:9092

# Terminal 2: Producer contínuo
kafka-producer-perf-test.sh \
  --topic ha-test \
  --num-records 1000000 \
  --throughput 1000 \
  --record-size 1024 \
  --producer-props bootstrap.servers=localhost:9092 acks=all

# Terminal 3: Monitorar under-replicated partitions
watch -n 1 'kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions'

# Terminal 4: MATAR um broker
docker stop kafka-2
# ou
kill -9 <broker-pid>

# Observar:
# - Tempo de eleição de leaders
# - Producer continua funcionando? (se min.insync.replicas=1, sim)
# - Tempo de recuperação
```

### Simular Falha de Consumer

```bash
# Consumer group com múltiplos consumers
# Terminal 1
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic ha-test \
  --group ha-consumer-group \
  --consumer-property session.timeout.ms=6000

# Terminal 2 (outro consumer)
kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic ha-test \
  --group ha-consumer-group \
  --consumer-property session.timeout.ms=6000

# Terminal 3: Monitorar consumer group
watch -n 1 'kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group ha-consumer-group \
  --describe'

# MATAR consumer do Terminal 1 (CTRL+C ou kill)

# Observar:
# - Tempo para detectar falha (session.timeout.ms)
# - Rebalance automático
# - Partições redistribuídas
```

---

## 📈 Métricas para Monitorar

### Broker Availability

```bash
# Under-replicated partitions (métrica CRÍTICA!)
kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions
# Valor ideal: 0
# > 0 = problemas de disponibilidade

# Offline partitions
kafka.controller:type=KafkaController,name=OfflinePartitionsCount
# Valor ideal: 0
# > 0 = partições INDISPONÍVEIS

# Leader election rate
kafka.controller:type=ControllerStats,name=LeaderElectionRateAndTimeMs
```

### Consumer Group Health

```bash
# Consumer lag
kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group seu-grupo \
  --describe

# Rebalance rate
kafka.consumer:type=consumer-coordinator-metrics,client-id=*
  - rebalance-rate-per-hour
  - rebalance-latency-avg
```

### Kafka Streams State Restoration

```bash
# Restoration time
org.apache.kafka.streams:type=stream-state-metrics,task-id=*
  - restore-latency-avg
  - restore-latency-max
```

---

## 🎯 Checklist de Alta Disponibilidade

**Configurações:**
- [ ] `min.insync.replicas=1` (ou balanceado com durabilidade)
- [ ] `unclean.leader.election.enable=true` (se puder tolerar perda)
- [ ] `num.recovery.threads.per.data.dir` = número de discos
- [ ] `session.timeout.ms` tão baixo quanto viável (6-10s)
- [ ] `num.standby.replicas=1` (Kafka Streams)

**Infraestrutura:**
- [ ] Replication factor >= 3
- [ ] Múltiplos brokers em diferentes racks/AZs
- [ ] RAID configurado para performance
- [ ] JVM GC otimizado

**Monitoramento:**
- [ ] Alert: UnderReplicatedPartitions > 0
- [ ] Alert: OfflinePartitionsCount > 0
- [ ] Alert: Consumer lag alto
- [ ] Alert: Rebalance frequente

**Testes:**
- [ ] Teste de falha de broker executado
- [ ] Teste de falha de consumer executado
- [ ] Tempo de recovery medido
- [ ] Runbook de recovery documentado

---

## ⚖️ Trade-offs Críticos

| Configuração | Availability ⬆️ | Durability ⬇️ |
|--------------|----------------|---------------|
| `min.insync.replicas=1` | ✅ Maior | ⚠️ Menor |
| `unclean.leader.election=true` | ✅ Maior | ❌ Risco de perda |
| `session.timeout.ms` baixo | ✅ Recovery rápido | ⚠️ Soft failures |
| `acks=1` (producer) | ✅ Menor bloqueio | ⚠️ Menor garantia |

---

## 💡 Dicas Práticas

1. **Conheça seus limites** - Teste cenários de falha em staging
2. **Balance com durabilidade** - Alta availability geralmente sacrifica durabilidade
3. **Monitore UnderReplicatedPartitions** - Métrica #1 de availability
4. **Documente runbooks** - Saiba como reagir a falhas
5. **Use rack awareness** - Distribua replicas entre racks/AZs
6. **Teste rebalances** - Garanta que consumers recuperam rapidamente
7. **Otimize JVM GC** - Evite soft failures de consumer

---

## 🎯 Próximo Passo

Disponibilidade garantida! Agora vamos explorar como nunca perder dados:

**Day 5: Otimização para Durability** 🛡️

---

**Always Available! 🚀**
