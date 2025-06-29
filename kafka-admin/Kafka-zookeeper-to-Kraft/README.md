# [Apache Kafka - Migrar Zookeeper para Kraft](https://www.youtube.com/@espetinhodekafka)

Criar nosso network
```bash
docker network create kafka-net
```
Abra 3 terminais diferentes e execute em cada um os containers abaixo:

Terminal 1: 
```bash
docker run -it --name kafka01 --hostname kafka01 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.9.1 bash
```
Terminal 2:
```bash
docker run -it --name kafka02 --hostname kafka02 --network=kafka-net  -e PATH="/opt/kafka/bin/:$PATH" --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.9.1 bash
```
Terminal 3
```bash
docker run -it --name kafka03 --hostname kafka03 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.9.1 bash
```

# Zookeeper configure

```bash
cat <<EOF> /opt/kafka/config/zookeeper.properties
timeTick=2000
dataDir=/data/zookeeper/
clientPort=2181
initLimit=5
syncLimit=2
4lw.commands.whitelist=*

server.1=kafka01:2888:3888
server.2=kafka02:2888:3888
server.3=kafka03:2888:3888
EOF
```

Generate ID's
```bash
mkdir /data/zookeeper
hostname | tail -c 2 > /data/zookeeper/myid
```

Start Zoookeeper
```bash
zookeeper-server-start.sh -daemon /opt/kafka/config/zookeeper.properties
```

Check zookeeper
```bash
echo -e ruok | nc localhost 2181 ; echo
```

# Kafka Configs
```bash
myid=$(hostname | tail -c 2) && sed -i "s/broker.id=0/broker.id=$myid/g" "/opt/kafka/config/server.properties"
sed -i "s/tmp/data/g" "/opt/kafka/config/server.properties"
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

Salve o seu cluster ID
```bash
zookeeper-shell.sh localhost:2181 get /cluster/id
```

```bash
awk -F= '/^cluster.id=/{print $2}' /data/kafka-logs/meta.properties
```
## Agora, apenas no primeiro terminal.
### Create a topic:

```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test-10 --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3 --config retention.ms=600000 --config segment.ms=600000 
```
Describe:
```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test-10 --describe 
```
Abre um novo terminal, e rode o script do producer.
```bash
docker run -it --name kafka04 --hostname kafka04 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" -v .:/data --rm apache/kafka:3.9.1 bash

/data/producer.sh
```

Outro Terminal para rodarmos o consumer:
```bash
docker run -it --name kafka05 --hostname kafka05 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" -v .:/data --rm apache/kafka:3.9.1 bash

kafka-console-consumer.sh --bootstrap-server kafka01:9092 --topic test-10 --from-beginning"
```

# Controller Conf

Abra 3 terminais diferentes e execute em cada um os containers abaixo:

Terminal 1: 
```bash
docker run -it --name controller11 --hostname controller11 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.1 bash
```
Terminal 2:
```bash
docker run -it --name controller12 --hostname controller12 --network=kafka-net  -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.1 bash
```
Terminal 3
```bash
docker run -it --name controller13 --hostname controller13 --network=kafka-net -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.1 bash
```

Executar em todos controllers

```bash
myid=$(hostname | tail -c 2) && sed -i "s/node.id=1/node.id=1$myid/g" "/opt/kafka/config/kraft/controller.properties"
sed -i "s/localhost/controller1$myid/g" "/opt/kafka/config/kraft/controller.properties"
```

Adicionar configuracao para habilitar a migracao
```bash
cat <<EOF>> /opt/kafka/config/kraft/controller.properties
# Enable the migration
zookeeper.metadata.migration.enable=true

# ZooKeeper client configuration
zookeeper.connect=kafka01:2181,kafka02:2181,kafka03:2181
EOF
```

Vamos gerar UUID
```bash
CLUSTER_ID=K4ywppaST4yUSdG6EEgjTw
CONTROLLER_0_UUID="$(kafka-storage.sh random-uuid)"
CONTROLLER_1_UUID="$(kafka-storage.sh random-uuid)"
CONTROLLER_2_UUID="$(kafka-storage.sh random-uuid)"
```

Rode este comando para faciltar, e entao copie o resultado e copie em cada container.
```bash
echo kafka-storage.sh format --cluster-id ${CLUSTER_ID} --initial-controllers "11@controller11:9093:${CONTROLLER_0_UUID},12@controller12:9093:${CONTROLLER_1_UUID},13@controller13:9093:${CONTROLLER_2_UUID}" --config /opt/kafka/config/kraft/controller.properties
```

Start kafka Controller:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/kraft/controller.properties
```

Describe Kraft
```bash
kafka-metadata-quorum.sh --bootstrap-controller controller11:9093 describe --status
```

Identificar o Controler Leader

```bash
kafka-metadata-quorum.sh --bootstrap-controller controller11:9093 describe --status | grep LeaderId
```

Vamos monitorar os logs

```bash
tail -f /opt/kafka/logs/controller.log
```


# Configurar Kafka Brokers para migracao

Migration and Controller config
```bash
cat <<EOF>> /opt/kafka/config/server.properties

# listener
listener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT
# Set the IBP
inter.broker.protocol.version=3.9

# Enable the migration
zookeeper.metadata.migration.enable=true

# KRaft controller quorum configuration
controller.quorum.bootstrap.servers=controller11:9093,controller12:9093,controller13:9093
controller.listener.names=CONTROLLER
EOF
```

Stop 1 by 1 restart Kafka broker services.

```bash
kafka-server-stop.sh
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

```bash
kafka-metadata-quorum.sh --bootstrap-controller controller11:9093 describe --status
```

## Adicionar as configuracoes para Kraft aos Brokers

Add node.id, executar em todos os Brokers
```bash
sed -i "s/broker.id/node.id/g" "/opt/kafka/config/server.properties"
echo process.roles=broker >> "/opt/kafka/config/server.properties"
```

Stop 1 by 1 restart Kafka broker services.
```bash
kafka-server-stop.sh
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

```bash
kafka-metadata-quorum.sh --bootstrap-controller controller11:9093 describe --status
```

## Agora, apenas no primeiro terminal.
Create a topic:

```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test2 --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3
```
Describe:
```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test2 --describe
```
Produzindo mensagens
```bash
    kafka-verifiable-producer.sh --bootstrap-server kafka01:9092 --max-messages 100 --topic test2
```

## Removendo o Zookeeper

Comentar as linhas em referencia ao Zookeeper em todos os brokers, e depois restart em todos os brokers
```bash
sed -i 's/^zookeeper.metadata.migration.enable=true/# zookeeper.metadata.migration.enable=true/' /opt/kafka/config/server.properties
sed -i 's/^istener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT/# istener.security.protocol.map=PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT/' /opt/kafka/config/server.properties
```

Comentar as linhas em referencia ao Zookeeper em todos os controllers, e depois restart em todos os controllers
```bash
sed -i 's/^zookeeper.metadata.migration.enable=true/# zookeeper.metadata.migration.enable=true/' "/opt/kafka/config/kraft/controller.properties"
sed -i 's/^zookeeper.connect=kafka01:2181,kafka02:2181,kafka03:2181/# zookeeper.connect=kafka01:2181,kafka02:2181,kafka03:2181/' "/opt/kafka/config/kraft/controller.properties"
```
Stop 1 by 1 restart Kafka broker services.
```bash
kafka-server-stop.sh
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

```bash
kafka-metadata-quorum.sh --bootstrap-controller controller11:9093 describe --status
```
Stop 1 by 1 restart Kafka  Controller:

```bash
kafka-server-stop.sh
```
Start Controller
```bash
kafka-server-start.sh -daemon /opt/kafka/config/kraft/controller.properties
```

## Agora, apenas no primeiro terminal.
Create a topic:

```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test3 --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3
```
Describe:
```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test3 --describe
```
Produzindo mensagens
```bash
kafka-verifiable-producer.sh --bootstrap-server kafka01:9092 --max-messages 100 --topic test3
```