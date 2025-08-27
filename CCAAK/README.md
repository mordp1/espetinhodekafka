# Confluent Certified Administrator for Apache Kafka®


Roteiro Completo para Certificação Confluent Certified Administrator for Apache Kafka® (CCAAK)

📋 Índice do Roteiro

1. Kafka Fundamentals - Conceitos Básicos

- Arquitetura do Apache Kafka
- Brokers, Topics, Partitions e Offsets
- Producers e Consumers
- Zookeeper vs KRaft
- Cluster Management

2. Replicação e Garantias de Entrega

- Replication Factor
- Leader e Follower Brokers
- ACK Levels (0, 1, all/-1)
- min.insync.replicas
- ISR (In-Sync Replicas)

3. Alta Disponibilidade (High Availability)

- Configurações de Failover
- Leader Election
- Partition Reassignment
- Broker Recovery
- linger.ms e batch.size para Producers

4. Performance e Throughput

- Configurações de Broker para Performance
- Network Threads (num.network.threads)
- I/O Threads (num.io.threads)
- Log Retention e Compaction
- JVM Tuning

5. Segurança e Autenticação

- SSL/TLS Configuration
- SASL/SCRAM Authentication
- ACLs (Access Control Lists)
- Authorization
- Network Security

6. Monitoramento e Logging

- Log4j Configuration
- Client ID Tracking
- Connection Logs
- Metrics e JMX
- Troubleshooting

7. Consumer Management

- Consumer Groups
- Consumer Lag
- Partition Assignment
- Rebalancing
- Offset Management

8. Network e Quotas

- Network Configuration
- IP-based Quotas
- Client Quotas
- Request Rate Limiting

9. Kafka Connect

- Distributed Mode
- Connector Status
- Connector Logs
- SMT (Single Message Transforms)
- Error Handling

## Kafka Fundamentals & Replication:

- Arquitetura básica do Kafka
- Replication Factor vs min.insync.replicas
- ACK levels e garantias de entrega
- Demonstração prática de failover

#### Comandos Práticos:

```bash
# Criar tópico com replication factor
kafka-topics.sh --create --topic test-ha --partitions 3 --replication-factor 3 --config min.insync.replicas=2

# Verificar descrição do tópico
kafka-topics.sh --describe --topic test-ha

# Testar producer com diferentes ACKs
kafka-console-producer.sh --topic test-ha --producer-property acks=all
``` 

## Alta Disponibilidade & Performance:

- Configurações para alta disponibilidade
- Partition reassignment
- Otimizações de performance
- Network e I/O threads

#### Configurações Importantes:

```properties
# Alta Disponibilidade
default.replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false

# Performance
num.network.threads=8
num.io.threads=16
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
``` 

## Segurança & Monitoramento:

- SSL/SASL configuration
- ACLs práticos
- Log4j configuration
- Troubleshooting de conexões

#### Configurações de Segurança:

```properties
# SSL
listeners=SSL://localhost:9093
ssl.keystore.location=/path/to/keystore
ssl.truststore.location=/path/to/truststore

# SASL/SCRAM
sasl.enabled.mechanisms=SCRAM-SHA-256
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-256
```

#### Consumer Management & Kafka Connect:

- Consumer groups e lag monitoring
- Partition assignment strategies
- Kafka Connect distributed mode
- Troubleshooting connectors

#### Comandos de Monitoramento:

```bash
# Consumer lag
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group mygroup

# Connect status
curl http://localhost:8083/connectors/my-connector/status

# Administração básica
kafka-topics.sh --create/list/describe/delete
kafka-console-producer.sh
kafka-console-consumer.sh
kafka-consumer-groups.sh

# Reassignment
kafka-reassign-partitions.sh

# ACLs
kafka-acls.sh --add/list/remove

# Connect
curl endpoints para status/config/logs

# Broker essentials
broker.id
log.dirs
num.network.threads
num.io.threads
default.replication.factor
min.insync.replicas

# Producer essentials
acks
linger.ms
batch.size

# Consumer essentials
group.id
enable.auto.commit
auto.offset.reset
```

## 📚 Checklist de Preparação

Conceitos Obrigatórios:
- Diferença entre replication factor e min.insync.replicas
- Como funciona leader election
- Impacto do unclean.leader.election.enable
- Configurações de linger.ms e batch.size
- Consumer group rebalancing
- Partition reassignment process
- SSL vs SASL authentication
- ACL syntax e permissões
- Log4j configuration para debugging
- Kafka Connect error handling

#### Comandos Essenciais:

```bash 
# Administração básica
kafka-topics.sh --create/list/describe/delete
kafka-console-producer.sh
kafka-console-consumer.sh
kafka-consumer-groups.sh

# Reassignment
kafka-reassign-partitions.sh

# ACLs
kafka-acls.sh --add/list/remove

# Connect
curl endpoints para status/config/logs
``` 

## Configurações Críticas:

```properties
# Broker essentials
broker.id
log.dirs
num.network.threads
num.io.threads
default.replication.factor
min.insync.replicas

# Producer essentials
acks
linger.ms
batch.size

# Consumer essentials
group.id
enable.auto.commit
auto.offset.reset
```

# Livros e Links

- Kafka: The Definitive Guide Real-Time Data and Stream Processing at Scale

- Kafka Connect - Build Data Pipelines by Integrating Existing Systems

- https://github.com/danielsobrado/CCDAK-Exam-Questions

- https://assets.confluent.io/m/725871503f2ffd29/original/20250414-DS-Certified_Administrator_Apache_Kafka.pdf

- https://training.confluent.io/examdetail/confluent-admin-exam

- https://rpcandidate.prometric.com/#system-check-tag

- https://www.confluent.io/resources/white-paper/optimizing-your-apache-kafka-deployment/