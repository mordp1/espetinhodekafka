# Prepare Docker

```bash
docker network create kafka-net
```
## Run over differents terminal the commands:
```bash
docker run -it --name kafka01 --hostname kafka01 --network=kafka-net --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash
```
```bash
docker run -it --name kafka02 --hostname kafka02 --network=kafka-net --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash
```
```bash
docker run -it --name kafka03 --hostname kafka03 --network=kafka-net --tmpfs /data:noexec,size=100000000,mode=1777 --rm apache/kafka:3.7.1 bash
```

## Export Path

```bash
export PATH=/opt/kafka/bin/:$PATH
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
## Generate ID's
```bash
mkdir /data/zookeeper
hostname | tail -c 2 > /data/zookeeper/myid
```


## Start Zoookeeper
```bash
zookeeper-server-start.sh -daemon /opt/kafka/config/zookeeper.properties
```

## Check zookeeper
```bash
echo -e ruok | nc localhost 2181 ; echo
```

# Kafka Configs
```bash
myid=$(hostname | tail -c 2) && sed -i "s/broker.id=0/broker.id=$myid/g" "/opt/kafka/config/server.properties"
sed -i "s/tmp/data/g" "/opt/kafka/config/server.properties"
echo log.segment.bytes=1073741 >> /opt/kafka/config/server.properties
```

## Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/server.properties
```

## Create a topic:
```bash
kafka-topics.sh --bootstrap-server localhost:9092 --topic test --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3
```

```bash
kafka-topics.sh --bootstrap-server localhost:9092 --topic test --describe
```

```bash
cd /tmp
wget https://github.com/yahoo/CMAK/releases/download/3.0.0.6/cmak-3.0.0.6.zip
unzip cmak-3.0.0.6.zip
```

```bash
cd cmak-3.0.0.6
export ZK_HOSTS="localhost:2181" && bin/cmak -Dconfig.file=conf/application.conf -Dhttp.port=9000
```

## Dump of messages
```bash
kafka-dump-log.sh --files 00000000000000000000.log --deep-iteration --print-data-log
```

## Alter log_dir

```bash
cat <<EOF> /tmp/topics.json
    {"version":1,
    "partitions":[
     {"topic":"test","partition":0,"replicas":[1,2,3],"log_dirs":["/data2/kafka-logs","any","any"]},
     {"topic":"test","partition":1,"replicas":[1,2,3],"log_dirs":["/data2/kafka-logs","any","any"]},
     {"topic":"test","partition":2,"replicas":[1,2,3],"log_dirs":["/data2/kafka-logs","any","any"]}
    ]}
EOF
```

Execute command

```bash
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 --reassignment-json-file /tmp/topics.json --execute
```