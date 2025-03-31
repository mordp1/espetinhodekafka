# Links Ref.
https://strimzi.io/blog/2021/12/17/kafka-segment-retention/
https://aiven.io/docs/products/kafka/concepts/partition-segments
https://kafka.apache.org/documentation/#topicconfigs_retention.ms
https://www.redpanda.com/guides/kafka-performance-kafka-logs

# Preparando Docker
Criar nosso network

```bash
docker network create kafka-net
```
Abra 3 terminais diferentes e execute em cada um os containers abaixo:
Terminal 1: 

```bash
docker run -it --name kafka01 --hostname kafka01 --network=kafka-net --tmpfs /data:noexec,size=10000000,mode=1777 --tmpfs /data2:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash```

Terminal 2:

```bash
docker run -it --name kafka02 --hostname kafka02 --network=kafka-net --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash
```
Terminal 3

```bash
docker run -it --name kafka03 --hostname kafka03 --network=kafka-net --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash
```

Export Path para facilitar executar os comandos do kafka.

```bash
export PATH=/opt/kafka/bin/:$PATH
```

##  Execute os comandos abaixo nos 3 containers.
Zokeeper configure
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

Kafka Configs
```bash
myid=$(hostname | tail -c 2) && sed -i "s/broker.id=0/broker.id=$myid/g" "/opt/kafka/config/server.properties"
sed -i "s/tmp/data/g" "/opt/kafka/config/server.properties"
echo log.segment.bytes=1073741 >> /opt/kafka/config/server.properties
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

## Agora, apenas no primeiro terminal.
### Create a topic:

```bash
  kafka-topics.sh --bootstrap-server localhost:9092 --topic test --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3
```
Describe:
```bash
kafka-topics.sh --bootstrap-server localhost:9092 --topic test --describe
```
Produzindo mensagens
```bash
kafka-verifiable-producer.sh --bootstrap-server localhost:9092 --max-messages 1000000 --topic test
```
## DumpLogs
```bash
cd /data/kafka-logs/test-2
```

```bash
kafka-run-class.sh kafka.tools.DumpLogSegments --deep-iteration --print-data-log --files 00000000000000000000.log
or 
kafka-dump-log.sh --files 00000000000000000000.log --deep-iteration --print-data-log
```

```bash
kafka-run-class.sh kafka.tools.DumpLogSegments --deep-iteration --print-data-log --files 00000000000000078883.log
or
kafka-dump-log.sh --files 00000000000000078883.log --deep-iteration --print-data-log
```

```bash
kafka-run-class.sh kafka.tools.DumpLogSegments --deep-iteration --print-data-log --files 00000000000000000000.index
or
kafka-dump-log.sh --files 00000000000000000000.index --deep-iteration --print-data-log
```

```bash
kafka-run-class.sh kafka.tools.DumpLogSegments --deep-iteration --print-data-log --files 00000000000000000000.timeindex
or
kafka-dump-log.sh --files 00000000000000000000.timeindex --deep-iteration --print-data-log
```