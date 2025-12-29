# Apache Kafka - Production Ready

Guia completo sobre como preparar e operar Apache Kafka em ambientes de produção, abordando os principais pilares de qualidade e confiabilidade.

## 📚 Sobre este Material

Este material foi criado para compartilhar conhecimento prático sobre operação de Kafka em produção, cobrindo os aspectos essenciais que todo administrador e engenheiro deve dominar.

## 🎯 Objetivos

- Entender os requisitos fundamentais para Kafka em produção
- Dominar conceitos de throughput, latência, disponibilidade e durabilidade
- Aplicar boas práticas de configuração e monitoramento
- Preparar clusters Kafka resilientes e performáticos

## 📋 Conteúdo

### [Day 1 - Definitions](./Day1-Definitions/)
**Definições e Conceitos Fundamentais**


### [Day 2 - Throughput](./Day2-Throughput/)
**Otimização de Throughput**

Aprenda a maximizar a vazão de dados no Kafka:
- Configurações de broker para alta vazão
- Otimização de producers e consumers
- Batch size e linger.ms
- Compression types
- Network e I/O threads

**Configurações chave:**
```properties
# Producer
batch.size=16384
linger.ms=10
compression.type=lz4
buffer.memory=33554432

# Broker
num.network.threads=8
num.io.threads=16
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
```

**Métricas importantes:**
- Mensagens/segundo
- Bytes/segundo
- Taxa de compressão
- Utilização de rede

---

### [Day 3 - Latency](./Day3-Latency/)
**Minimização de Latência**

Técnicas para reduzir latência end-to-end:
- Trade-off entre throughput e latência
- Configuração de acks
- fetch.min.bytes e fetch.max.wait.ms
- Request timeout configurations
- Otimização de network round trips

**Configurações para baixa latência:**
```properties
# Producer
linger.ms=0
acks=1
compression.type=none

# Consumer
fetch.min.bytes=1
fetch.max.wait.ms=100

# Broker
replica.lag.time.max.ms=10000
```

**Métricas de latência:**
- Producer latency (request latency)
- Consumer lag
- End-to-end latency
- Replication latency

---

### [Day 4 - Availability](./Day4-Availability/)
**Alta Disponibilidade**

Estratégias para garantir disponibilidade do cluster:
- Replication factor adequado
- min.insync.replicas
- Rack awareness
- Leader election
- Failover automático
- Disaster recovery

**Configurações de HA:**
```properties
# Replicação
default.replication.factor=3
min.insync.replicas=2
unclean.leader.election.enable=false

# Failover
replica.lag.time.max.ms=30000
leader.imbalance.check.interval.seconds=300
auto.leader.rebalance.enable=true
```

---

### [Day 5 - Durability](./Day5-Durability/)
**Durabilidade dos Dados**

Garantindo que nenhuma mensagem seja perdida:
- Configuração de acks=-1/all
- Log flush policies
- Retenção de dados
- Backup e restore

**Configurações para durabilidade:**
```properties
# Producer
acks=all
enable.idempotence=true
max.in.flight.requests.per.connection=5

# Broker
log.flush.interval.messages=10000
log.flush.interval.ms=1000
min.insync.replicas=2

# Topic
retention.ms=604800000  # 7 dias
segment.ms=86400000     # 1 dia
```

**Garantias:**
- At-least-once delivery
- Exactly-once semantics
- Idempotência
- Transações

---

### [Day 6 - Comapare ](./Day6-Compare-1/) e [Day 7 - Compare](./Day7-Compare-2/)
**Consolidação e Melhores Práticas**

Integrando todos os conceitos:
- Balanceamento dos 4 pilares (Throughput, Latency, Availability, Durability)
- Trade-offs em produção
- Monitoramento holístico
- Troubleshooting avançado
- Checklist de produção

## 🔗 Recursos Adicionais

**Documentação Oficial:**
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Kafka Configuration Reference](https://kafka.apache.org/documentation/#configuration)
- [Kafka Operations](https://kafka.apache.org/documentation/#operations)

**Melhores Práticas:**
- [Confluent Production Checklist](https://docs.confluent.io/platform/current/kafka/deployment.html)
- [LinkedIn Kafka Best Practices](https://engineering.linkedin.com/kafka)

## 📺 Canal no YouTube

Para mais conteúdo sobre Apache Kafka:
[https://www.youtube.com/@espetinhodekafka](https://www.youtube.com/@espetinhodekafka)

## 🤝 Contribuindo

Sinta-se à vontade para:
- Reportar erros ou inconsistências
- Sugerir melhorias
- Compartilhar casos de uso reais
- Adicionar exemplos práticos

## 📝 Notas

- Este material é baseado em experiências práticas com Kafka em produção
- As configurações apresentadas são exemplos e devem ser ajustadas para cada caso de uso
- Sempre teste em ambientes não-produtivos antes de aplicar mudanças
- Monitore continuamente e ajuste baseado em métricas reais

## 🚀 Como Usar Este Material

1. **Leia sequencialmente:** Os módulos foram projetados para construir conhecimento progressivamente
2. **Pratique:** Execute os comandos e experimentos sugeridos
3. **Analise os diagramas:** Use os arquivos Excalidraw para visualizar conceitos
4. **Aplique no seu contexto:** Adapte as configurações para suas necessidades específicas

---

**Bons estudos e boa produção com Apache Kafka! 🎉**
