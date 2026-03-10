# Guia de Testes de Benchmark do Kafka

Guia completo para realizar benchmarks do Apache Kafka usando binários nativos. Este guia irá ajudá-lo a testar I/O de disco, throughput de rede, taxas de produção/consumo de mensagens e performance geral.

> **📦 Ferramenta de Teste Automatizada Disponível!**  
> Criei um repositório completo com scripts bash e ferramentas Python para automatizar estes testes de benchmark com relatórios HTML interativos:  
> **[kafka-perf-test](https://github.com/mordp1/kafka-perf-test)** - Inclui setup Docker Compose, scripts bash nativos e implementação Python para testes de performance facilitados.

## Índice

1. [Pré-requisitos](#pré-requisitos)
2. [Configuração do Ambiente de Teste](#configuração-do-ambiente-de-teste)
3. [Cenários de Benchmark](#cenários-de-benchmark)
4. [Ferramentas de Monitoramento](#ferramentas-de-monitoramento)
5. [Execução de Benchmark Passo a Passo](#execução-de-benchmark-passo-a-passo)
6. [Interpretando Resultados](#interpretando-resultados)

## Pré-requisitos

- Cluster Kafka em execução (nó único ou multi-nós)
- Binários do Kafka instalados (`kafka-topics.sh`, `kafka-producer-perf-test.sh`, `kafka-consumer-perf-test.sh`)
- Ferramentas de monitoramento: `iostat`, `iftop`/`nethogs`, `top`/`htop`
- Espaço em disco suficiente (recomendado: 10GB+ livres)
- Acesso de rede aos brokers Kafka

## Configuração do Ambiente de Teste

### 1. Criar Tópicos de Teste

```bash
# Criar tópicos com diferentes configurações
kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic p1-rf1 \
  --partitions 1 \
  --replication-factor 1 \
  --config retention.ms=3600000

kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic p1-rf3 \
  --partitions 1 \
  --replication-factor 3 \
  --config retention.ms=3600000

kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic p3-rf3 \
  --partitions 3 \
  --replication-factor 3 \
  --config retention.ms=3600000

kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic p12-rf3 \
  --partitions 12 \
  --replication-factor 3 \
  --config retention.ms=3600000

kafka-topics.sh --create \
  --bootstrap-server localhost:29092 \
  --topic p30-rf3 \
  --partitions 30 \
  --replication-factor 3 \
  --config retention.ms=3600000
```

### 2. Verificar Tópicos

```bash
kafka-topics.sh --list --bootstrap-server localhost:29092
kafka-topics.sh --describe --bootstrap-server localhost:29092
```

## Cenários de Benchmark

### Impacto de Partições e Fator de Replicação

**Por que testar 1 partição com RF=1 vs RF=3?**

Este teste estabelece o throughput base por partição e ajuda você a entender:
- **Throughput máximo por partição**: Quantos dados uma única partição pode processar?
- **Overhead de replicação**: Como o fator de replicação afeta a performance?
- **Escalonamento de partições**: Quantas partições você precisa para o throughput esperado?

#### Entendendo os Resultados

Quando você testa com **1 partição, RF=1**:
- Você obtém o **throughput máximo que uma única partição pode alcançar** sem overhead de replicação
- Isso representa a capacidade "single-threaded" de uma partição
- Exemplo: Se você obtém 50 MB/s com 1 partição RF=1, essa é sua baseline por partição

Quando você testa com **1 partição, RF=3**:
- Você vê o **impacto da replicação** (escrevendo em 3 brokers ao invés de 1)
- O throughput será menor devido ao overhead de rede e coordenação
- Exemplo: Você pode obter 30 MB/s com 1 partição RF=3

#### Calculando Requisitos de Partições

Uma vez que você conhece seu throughput baseline por partição, pode calcular quantas partições precisa:

```
Partições Necessárias = Throughput Total Esperado / Throughput por Partição
```

**Exemplo:**
- Baseline: 1 partição RF=1 = 50 MB/s
- Seu requisito: 200 MB/s de throughput total
- Cálculo: 200 MB/s ÷ 50 MB/s = 4 partições necessárias (mínimo)

**Com Replicação (RF=3):**
- Baseline: 1 partição RF=3 = 30 MB/s  
- Seu requisito: 200 MB/s de throughput total
- Cálculo: 200 MB/s ÷ 30 MB/s = 7 partições necessárias (mínimo)

#### Configuração de Teste

```bash
# Teste de produtor
kafka-producer-perf-test.sh \
  --topic p1-rf1 \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

# Teste 2: 1 Partição, Fator de Replicação 3 (Overhead de replicação)
# Teste de produtor (mesmos parâmetros)
kafka-producer-perf-test.sh \
  --topic p1-rf3 \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

kafka-producer-perf-test.sh \
  --topic p3-rf3 \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

kafka-producer-perf-test.sh \
  --topic p12-rf3 \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

kafka-producer-perf-test.sh \
  --topic p30-rf3 \
  --num-records 1000000 \
  --record-size 1024 \
  --throughput -1 \
  --producer-props bootstrap.servers=localhost:29092,localhost:39092,localhost:49092

# Compare os resultados:
# - RF=1: Este é seu throughput máximo por partição
# - RF=3: Isso mostra o overhead de replicação
# - Diferença: Mostra o custo da replicação
```

**Principais Insights:**
- **Throughput RF=1** = Capacidade máxima por partição (sem replicação)
- **Throughput RF=3** = Capacidade real por partição (com replicação)
- **Diferença** = Overhead de replicação (tipicamente redução de 30-50%)
- Use **resultados RF=3** para planejamento de produção (mais realista)
- Use **resultados RF=1** para entendimento do máximo teórico

**Exemplo Prático:**
```
Cenário: Você precisa processar 500 MB/s de throughput com RF=3

Passo 1: Testar 1 partição RF=3 → Resultado: 35 MB/s por partição
Passo 2: Calcular: 500 MB/s ÷ 35 MB/s = ~15 partições necessárias
Passo 3: Criar tópico com 15+ partições (arredondar para cima por segurança)
Passo 4: Com 15 partições, você pode processar: 15 × 35 MB/s = 525 MB/s ✅
```

### Teste de Latência Ponta a Ponta

### Usando a Ferramenta EndToEndLatency (Recomendado)

O script `kafka-e2e-latency.sh` fornece medições precisas de latência ponta a ponta ao produzir e consumir mensagens de forma controlada, medindo o tempo completo de ida e volta.

**Uso:**
```bash
kafka-e2e-latency.sh <broker_list> <topic> <num_messages> <producer_acks> <message_size_bytes> [properties_file]
```

**Parâmetros:**
- `broker_list`: Lista separada por vírgulas dos brokers Kafka (ex: `localhost:29092,localhost:39092`)
- `topic`: Nome do tópico a ser usado no teste
- `num_messages`: Número de mensagens a enviar/receber
- `producer_acks`: Configuração de acknowledgment do produtor (0, 1, ou all)
- `message_size_bytes`: Tamanho de cada mensagem em bytes
- `properties_file`: (Opcional) Caminho para arquivo de propriedades adicionais

**Exemplos de Testes:**

```bash
# Teste 1: Teste básico de latência com mensagens de 1KB
kafka-e2e-latency.sh \
  localhost:29092,localhost:39092,localhost:49092 \
  latency-test \
  10000 \
  1 \
  1024

# Teste 2: Mensagens pequenas (100 bytes) com acks=all
kafka-e2e-latency.sh \
  localhost:29092 \
  latency-test \
  10000 \
  all \
  100

# Teste 3: Mensagens grandes (10KB) para testar impacto na latência
kafka-e2e-latency.sh \
  localhost:29092 \
  latency-test \
  5000 \
  1 \
  10240
```

**Entendendo os Resultados:**

A ferramenta retorna estatísticas de latência baseadas em percentis:
- **Latência média (Average latency)**: Tempo médio de ida e volta
- **Percentil 50 (mediana)**: Metade das mensagens completam mais rápido que isso
- **Percentil 95**: 95% das mensagens completam mais rápido que isso
- **Percentil 99**: 99% das mensagens completam mais rápido que isso
- **Percentil 99.9**: Mede latência no pior caso para a maioria das mensagens
- **Latência máxima (Max latency)**: Máximo absoluto observado

**Indicadores de Boa Performance:**
- Latência média baixa (< 10ms para cluster local, < 50ms para remoto)
- Pequena diferença entre média e percentil 95 (performance consistente)
- Percentil 99 < 100ms (sem outliers significativos)
- Latência máxima não muito distante do percentil 99.9

**Comparando Diferentes Configurações:**

```bash
# Comparar impacto de ACKS na latência
# ACKS=1 (acknowledgment apenas do líder)
kafka-e2e-latency.sh localhost:29092 latency-test 10000 1 1024

# ACKS=all (acknowledgment de todas as réplicas)
kafka-e2e-latency.sh localhost:29092 latency-test 10000 all 1024

# Comparar impacto do tamanho da mensagem
# Mensagens pequenas
kafka-e2e-latency.sh localhost:29092 latency-test 10000 1 100

# Mensagens grandes
kafka-e2e-latency.sh localhost:29092 latency-test 10000 1 10240
```

## Ferramentas de Monitoramento

### Testes Baseline de Performance de Disco

Antes de executar benchmarks do Kafka, estabeleça uma baseline para a performance do seu disco. Isso ajuda a identificar se o I/O do disco é um gargalo.

#### Testar Throughput de Escrita (arquivo de 1GB)

```bash
# Testar throughput de escrita (arquivo de 1GB)
# Substitua /var/lib/kafka/data pelo seu diretório de dados do Kafka
dd if=/dev/zero of=/tmp/tmpfile bs=1M count=1024 conv=fsync

# Exemplo de saída:
# 1024+0 records in
# 1024+0 records out
# 1073741824 bytes (1.1 GB, 1.0 GiB) copied, X.XXX s, XXX MB/s
```

**Interpretação:**
- Maior MB/s = escritas de disco mais rápidas
- SSD típico: 200-500 MB/s
- HDD típico: 50-150 MB/s
- Se isso for lento, a performance de escrita do Kafka será limitada

#### Testar Throughput de Leitura

```bash
# Testar throughput de leitura
dd if=/tmp/tmpfile of=/dev/null bs=1M count=1024

# Limpar arquivo de teste após os testes
rm /tmp/tmpfile
```

**Interpretação:**
- Maior MB/s = leituras de disco mais rápidas
- Velocidade de leitura é tipicamente mais rápida que escrita
- Performance do consumidor depende da velocidade de leitura

#### Alternativa: Testar com arquivo menor (teste mais rápido)

```bash
# Teste rápido com arquivo de 100MB
dd if=/dev/zero of=/var/lib/kafka/data/tmpfile bs=1M count=100 conv=fsync
dd if=/var/lib/kafka/data/tmpfile of=/dev/null bs=1M count=100
rm /var/lib/kafka/data/tmpfile
```

### Monitoramento de I/O de Disco

```bash
# Monitorar I/O de disco em tempo real (atualizar a cada 2 segundos)
iostat -x 2

# Monitorar disco específico
iostat -x /dev/sda 2

# Salvar em arquivo para análise posterior
iostat -x 2 > disk-io.log
```

Métricas principais para observar:
- `r/s`, `w/s`: Operações de leitura/escrita por segundo
- `rkB/s`, `wkB/s`: KB lidos/escritos por segundo
- `%util`: Porcentagem de tempo que o dispositivo estava ocupado
- `await`: Tempo médio de espera para requisições de I/O

### Monitoramento de Rede

```bash
# Usando iftop (instalar: sudo apt install iftop / brew install iftop)
sudo iftop -i eth0

# Usando nethogs (instalar: sudo apt install nethogs / brew install nethogs)
sudo nethogs

# Usando netstat/ss para conexões
netstat -an | grep 9092
ss -tn | grep 9092

# Throughput de rede
iftop -i eth0 -t -s 10
```

### Monitoramento de CPU e Memória

```bash
# Usando top
top -p $(pgrep -f kafka)

# Usando htop (interface melhor)
htop -p $(pgrep -f kafka)

# Usando vmstat
vmstat 2

# Uso de memória
free -h
```

### Monitoramento Específico do Kafka

```bash
# Lag do consumidor
kafka-consumer-groups.sh \
  --bootstrap-server localhost:29092 \
  --group benchmark-group-1 \
  --describe

# Métricas de tópico (se JMX habilitado)
# Conectar em: localhost:9999/jolokia
# Ou usar jconsole/jvisualvm
```

### Métricas de Performance do Produtor

Métricas principais do `kafka-producer-perf-test.sh`:
- **Throughput (MB/sec)**: Mensagens escritas por segundo
- **Avg Latency (ms)**: Tempo médio para acknowledgment
- **Max Latency (ms)**: Latência máxima experimentada
- **Records/sec**: Número de registros processados por segundo

**Indicadores de boa performance:**
- Alto throughput com baixa latência
- Latência consistente (baixo desvio padrão)
- Alto records/sec para mensagens pequenas
- Alto MB/sec para mensagens grandes

### Métricas de Performance do Consumidor

Métricas principais do `kafka-consumer-perf-test.sh`:
- **Throughput (MB/sec)**: Mensagens lidas por segundo
- **Records/sec**: Número de registros consumidos por segundo
- **Avg Latency (ms)**: Tempo médio para buscar mensagens
- **Fetch Time (ms)**: Tempo gasto buscando do broker

### Análise de I/O de Disco

- **Performance baseline do disco**: Compare resultados do teste `dd` com throughput do Kafka
  - Se throughput do Kafka está próximo da velocidade de escrita do `dd` → disco é o gargalo
  - Se throughput do Kafka é muito menor → outros gargalos (rede, CPU, configuração)
- **Alto `wkB/s`**: Kafka está escrevendo dados no disco
- **Alto `%util`**: Disco é um gargalo
- **Alto `await`**: I/O do disco está lento
- **Baixo `%util` com baixo throughput**: Gargalo de rede ou CPU

**Comparando Resultados:**
- Velocidade de escrita do `dd`: Capacidade baseline de escrita do disco
- Throughput do produtor Kafka: Deve estar próximo da velocidade de escrita do disco (se disco for o gargalo)
- Se throughput do Kafka << velocidade de escrita do disco: Procure outros gargalos (rede, CPU, config)

### Análise de Rede

- Monitorar uso de largura de banda
- Verificar saturação de rede
- Comparar com velocidades de escrita do disco (rede deve igualar ou exceder)

## Recursos Adicionais

- [Kafka Operations](https://kafka.apache.org/41/operations/)
- [Configuração do Produtor](https://kafka.apache.org/documentation/#producerconfigs)
- [Configuração do Consumidor](https://kafka.apache.org/documentation/#consumerconfigs)
- [Confluent OpenMessaging Benchmark](https://github.com/confluentinc/openmessaging-benchmark)
- [OpenMessaging Benchmark Framework](https://openmessaging.cloud/docs/benchmarks/)