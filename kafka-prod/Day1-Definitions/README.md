# Apache Kafka - Production Ready: Definições e Objetivos

## 🎯 Introdução

Apache Kafka® é a melhor tecnologia open source de event streaming que funciona "out of the box". Basta apontar suas aplicações cliente para o cluster Kafka e o Kafka cuida do resto: a carga é automaticamente distribuída entre os brokers, os brokers automaticamente utilizam zero-copy transfer para enviar dados aos consumidores, os consumer groups automaticamente rebalanceiam quando um consumidor é adicionado ou removido, os state stores usados pelas aplicações que utilizam Kafka Streams APIs são automaticamente backupeados no cluster, e a liderança de partições é automaticamente reatribuída em caso de falha de broker.


### A Questão Central

**Qual objetivo queremos alcançar com nosso Kafka?**

Esta é a pergunta que sua equipe precisa responder antes de configurar um cluster de produção. Você precisa forçar discussões sobre os casos de uso originais do negócio e quais são os objetivos principais.

## 🔍 Os Quatro Pilares de Otimização

Existem quatro objetivos de serviço principais que frequentemente envolvem trade-offs entre si:

### 1️⃣ Throughput (Vazão)
**Taxa em que os dados são movidos de producers para brokers ou de brokers para consumers**

**Quando otimizar para Throughput:**
- Casos de uso com milhões de escritas por segundo
- Pipelines de ingestão de dados em grande volume
- Processamento em batch de grandes volumes
- Integração de sistemas com alta taxa de eventos

**Exemplo:** Sistema de coleta de logs de milhares de servidores, onde o volume é mais importante que a velocidade individual de cada mensagem.

---

### 2️⃣ Latency (Latência)
**Tempo decorrido movendo mensagens end-to-end (de producers para brokers para consumers)**

**Quando otimizar para Latência:**
- Aplicações de chat/messaging em tempo real
- Websites interativos onde usuários seguem posts de amigos
- Stream processing em tempo real para IoT
- Sistemas de notificações instantâneas

**Exemplo:** Aplicação de chat onde o destinatário de uma mensagem precisa recebê-la com o mínimo de latência possível.

---

### 3️⃣ Durability (Durabilidade)
**Garantia de que mensagens committed não serão perdidas**

**Quando otimizar para Durabilidade:**
- Pipeline de microservices usando Kafka como event store
- Integração entre event streaming e armazenamento permanente (ex: AWS S3)
- Sistemas de missão crítica para conteúdo de negócio
- Auditoria e compliance

**Exemplo:** Sistema financeiro onde cada transação deve ser garantidamente persistida e nunca perdida.

---

### 4️⃣ Availability (Disponibilidade)
**Minimização de downtime em caso de falhas inesperadas**

**Quando otimizar para Disponibilidade:**
- Sistemas 24/7 que não podem ter downtime
- Aplicações de e-commerce durante períodos críticos
- Sistemas de monitoramento e alertas
- Plataformas de streaming de vídeo/áudio

**Exemplo:** Plataforma de streaming de eventos ao vivo que não pode parar durante transmissões importantes.

---

## ⚖️ O Teorema de Otimização do Kafka

### Trade-offs Inevitáveis

**Você não pode maximizar todos os objetivos ao mesmo tempo!**

Existem trade-offs ocasionais entre throughput, latência, durabilidade e disponibilidade. Você pode estar familiarizado com o trade-off comum entre throughput e latência, e talvez entre durabilidade e disponibilidade também.

```
📊 Exemplos de Trade-offs:

Throughput ↑  ⟺  Latency ↓
  (aumentar throughput geralmente aumenta latência)

Durability ↑  ⟺  Throughput ↓
  (maior durabilidade requer mais confirmações, reduzindo throughput)

Availability ↑  ⟺  Consistency ↓
  (maior disponibilidade pode comprometer consistência momentânea)
```

### Isso Não Significa Perder Completamente os Outros Objetivos

Otimizar um desses objetivos **não resulta em perder completamente os outros**. Significa apenas que eles estão **todos interconectados**, e portanto você não pode maximizar todos simultaneamente.

## 🎯 Decisão Estratégica: Qual Objetivo Priorizar?

### Processo de Decisão

Para descobrir quais objetivos você quer otimizar, considere:

1. **Casos de uso** que seu cluster vai servir
2. **Aplicações** que vão usar o Kafka
3. **Requisitos de negócio** - o que absolutamente não pode falhar
4. **Como o Kafka se encaixa** no pipeline do seu negócio

### Perguntas para sua Equipe

#### Para Throughput:
- Precisamos processar milhões de eventos por segundo?
- O volume de dados é mais importante que a velocidade individual?
- Podemos aceitar alguma latência adicional em troca de maior vazão?

#### Para Latência:
- Os usuários precisam ver resultados em tempo real?
- Milissegundos fazem diferença para o negócio?
- A experiência do usuário depende de respostas rápidas?

#### Para Durabilidade:
- Podemos perder alguma mensagem?
- Os dados são críticos para o negócio?
- Existem requisitos de auditoria ou compliance?

#### Para Disponibilidade:
- Quanto downtime é aceitável?
- Qual o impacto financeiro de uma indisponibilidade?
- Existem períodos críticos onde downtime é inaceitável?

## 🔧 Configuração por Objetivo

### Configuração Global vs Por Tópico

Se os objetivos de serviço se aplicam a todos os tópicos do cluster Kafka:
- Configure os parâmetros em **todos os brokers**

Se você quer otimizar coisas diferentes em tópicos diferentes:
- Use **topic overrides** para parâmetros específicos
- Sem um override explícito, o valor de configuração do broker se aplica

### Exemplo de Abordagem

```properties
# Configuração Global (broker)
default.replication.factor=3
min.insync.replicas=2

# Override para tópico de alta durabilidade
# kafka-configs.sh --alter --topic critical-transactions \
#   --add-config min.insync.replicas=3

# Override para tópico de baixa latência
# kafka-configs.sh --alter --topic real-time-notifications \
#   --add-config min.insync.replicas=1
```

## 📚 Parâmetros de Configuração

Existem **centenas de parâmetros de configuração diferentes** no Kafka. Esta série irá introduzir um pequeno subconjunto deles que são relevantes para otimizar cada um dos quatro objetivos.

### ⚠️ Importante

Os valores para alguns parâmetros de configuração dependem de outros fatores:
- Tamanho médio de mensagem
- Número de partições
- Hardware disponível
- Topologia de rede

Estes fatores podem variar muito de ambiente para ambiente. **Benchmarking é sempre crucial** para validar as configurações para seu deployment específico.

## 📖 Referências

- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
- [Confluent Platform Configuration Reference](https://docs.confluent.io/platform/current/installation/configuration/)
- Whitepaper: "Optimizing Your Apache Kafka® Deployment" - Confluent, Inc.
- [Fine-tune Kafka performance with the Kafka optimization theorem](https://developers.redhat.com/articles/2022/05/03/fine-tune-kafka-performance-kafka-optimization-theorem)

## 💡 Reflexão Final

> **"A flexibilidade de configuração do Kafka é proposital. Para garantir que seu deployment Kafka está otimizado para seus objetivos de serviço, você absolutamente deve investigar o tuning de alguns parâmetros de configuração e fazer benchmarking no seu próprio ambiente."**

O primeiro passo é sempre: **decidir qual objetivo você quer otimizar**.
