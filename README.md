# 🍢 Espetinho de Kafka 🍢

Conteúdo prático sobre Apache Kafka — desde os fundamentos até produção, certificação e muito mais.

Os vídeos foram criados com o objetivo de compartilhar conhecimento adquirido trabalhando com Kafka, para colegas de trabalho e amigos.

## 📺 Canal no Youtube

[https://www.youtube.com/@espetinhodekafka](https://www.youtube.com/@espetinhodekafka)

---

## 📚 Séries de Conteúdo

Aqui você encontra todos os comandos utilizados em cada episódio para facilitar o aprendizado e montar seu laboratório.

---

### 🟠 Kafka Fundamentals & Admin

Série introdutória cobrindo os principais conceitos do Apache Kafka e administração de clusters.

| Episódio | Tema |
|---|---|
| Day 1 | [Apache Kafka - Introdução, Producers e Consumers](https://www.youtube.com/watch?v=JR0stghYSho&t=1s) |
| Day 2 | [Apache Kafka - Arquitetura, Zookeeper e KRaft](https://youtu.be/IYcp8lr8L6E) |
| Day 3 | [Apache Kafka - Topic, Partition e Segment](https://youtu.be/gsaEp1WQZM8) |
| Day 4 | [Apache Kafka - Log, Stream e Broker](https://youtu.be/hDlod7c0CSw) |
| Day 5 | [Apache Kafka - Replicação de Partições e ISR](https://youtu.be/fiV3EOJiK-Y) |
| Day 6 | [Apache Kafka - Mensagem, Particionamento e Producers](https://youtu.be/DEgyY9KLi5s) |
| Day 7 | [Apache Kafka - Rebalance, Consumer e Consumer Group](https://youtu.be/Xuq7hRvxiTo) |
| Day 8 | [Apache Kafka - Entendendo o Kafka Connect](https://youtu.be/Obkg0sa4GB4) |
| Day 9 | [Kafka Connect - FileStream produzindo mensagens](https://www.youtube.com/watch?v=hdC5oMpgRlc) |
| Day 10 | [Apache Kafka - Troubleshooting e Administração de Cluster](https://www.youtube.com/watch?v=hdC5oMpgRlc) |

📁 [kafka-fundamentals-admin/README.md](kafka-fundamentals-admin/README.md)

---

### 🟡 Kafka Connect — Single Message Transforms (SMT)

Série prática sobre transformações de mensagens no Kafka Connect.

| Episódio | Tema |
|---|---|
| Day 1 | InsertField |
| Day 2 | ValueToKey e ExtractField |
| Day 3 | Flatten |
| Day 4 | RegexRouter |
| Day 5 | MaskField |
| Day 6 | InsertField (avançado) |
| Day 7 | TimestampRouter |

📁 [kafka-connect-SMT/README.md](kafka-connect-SMT/README.md)

---

### 🔵 AWS MSK — Apache Kafka na Amazon

Série sobre o serviço gerenciado Amazon MSK, cobrindo sizing, autenticação, monitoramento e armazenamento.

| Episódio | Tema |
|---|---|
| Day 1 | [AWS MSK - O Apache Kafka da Amazon](https://youtu.be/g4TztS7DmPs) |
| Day 2 | [AWS MSK - Sizing, Terraform e Autenticação/Autorização](https://youtu.be/391OaRMiy9k) |
| Day 3 | [AWS MSK - Quantidade de Brokers e Monitoramento](https://youtu.be/n5aAHiMLTlI) |
| Day 4 | [AWS MSK - CloudWatch e Prometheus](https://youtu.be/sxo2RFD_nUg) |
| Day 5 | [AWS MSK - Limites de Brokers, Console AWS e Migração](https://youtu.be/jQN0jifE-Rs) |
| Day 6 | [AWS MSK - Log Segments, Tiered Storage e Armazenamento Infinito](https://youtu.be/yUfx50KJw54) |

📁 [MSK/README.md](MSK/README.md)

---

### 🟢 Apache Kafka — Production Ready

Guia completo para preparar e operar Kafka em ambientes de produção, cobrindo os pilares de qualidade e confiabilidade.

| Episódio | Tema |
|---|---|
| Day 1 | Definitions — Definições e Conceitos Fundamentais |
| Day 2 | Throughput — Otimização de Vazão |
| Day 3 | Latency — Minimização de Latência |
| Day 4 | Availability — Alta Disponibilidade |
| Day 5 | Durability — Durabilidade dos Dados |
| Day 6 | Compare-1 — Comparações Práticas |
| Day 7 | Compare-2 — Comparações Avançadas |
| Day 8 | Benchmark — Testes de Performance |
| Day 9 | MirrorMaker — Replicação entre Clusters |

📁 [kafka-prod/README.md](kafka-prod/README.md)

---

### 🟣 Kafka no Kubernetes — Strimzi

Laboratório completo para rodar Apache Kafka no Kubernetes com o operador Strimzi.

- Configuração de cluster via Helm
- Kafka com 3 Brokers e configurações avançadas
- Métricas via JMX, Prometheus e Grafana
- Ingress e acesso externo ao cluster

📁 [kafka-strimzi/README.md](kafka-strimzi/README.md)

---

### ⚙️ Kafka Admin — Tópicos Avancados de Administração

Material de referência sobre administração e operação de clusters Kafka.

| Tópico | Descrição |
|---|---|
| Arquitetura | Visão geral da arquitetura |
| Disk Storage | Gestão de disco e armazenamento |
| Kafka Clients | Configuração e uso dos clientes |
| Kafka Cluster Install (KRaft) | Instalação de cluster no modo KRaft |
| Zookeeper to KRaft | Migração de Zookeeper para KRaft |
| Topic Retention | Políticas de retenção de tópicos |

📁 [kafka-admin/](kafka-admin/)

---

### 🏆 CCAAK — Confluent Certified Administrator for Apache Kafka®

Roteiro completo de estudos para a certificação **Confluent Certified Administrator for Apache Kafka®**, cobrindo:

- Fundamentos e arquitetura do Kafka
- Replicação e garantias de entrega (ACKs, ISR, min.insync.replicas)
- Alta Disponibilidade e Failover
- Performance e Throughput
- Segurança: SSL/TLS, SASL/SCRAM, ACLs
- Monitoramento, Logging e JMX
- Gerenciamento de Consumer Groups e Consumer Lag

📁 [CCAAK/README.md](CCAAK/README.md)

---


## 🤝 Contribuições

Sugestões, correções e PRs são bem-vindos! Se este conteúdo te ajudou, deixa um ⭐ no repositório e se inscreve no canal.