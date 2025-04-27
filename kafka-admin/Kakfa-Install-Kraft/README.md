# [Apache Kafka - Kafka cluster com Kraft](https://youtu.be/WM_4IuaoOSg)
Criar nosso network
```bash
docker network create kafka-net
```
Abra 3 terminais diferentes e execute em cada um os containers abaixo:
Terminal 1: 
```bash
docker run -it --name kafka01 --hostname kafka01 --network=kafka-net -p 9092:9092 -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.0 bash
```
Terminal 2:
```bash
docker run -it --name kafka02 --hostname kafka02 --network=kafka-net -p 9095:9095 -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.0 bash
```
Terminal 3
```bash
docker run -it --name kafka03 --hostname kafka03 --network=kafka-net -p 9094:9094 -e PATH="/opt/kafka/bin/:$PATH" --rm apache/kafka:3.9.0 bash
```

Controler Properties
```bash
myid=$(hostname | tail -c 2) && sed -i "s/node.id=1/node.id=1$myid/g" "/opt/kafka/config/kraft/controller.properties"
sed -i "s/localhost/kafka0$myid/g" "/opt/kafka/config/kraft/controller.properties"
```

Kafka Properties
```bash
myid=$(hostname | tail -c 2) && sed -i "s/node.id=2/node.id=$myid/g" "/opt/kafka/config/kraft/broker.properties"
sed -i "s/localhost/kafka0$myid/g" "/opt/kafka/config/kraft/broker.properties"
```

Vamos gerar UUID
```bash
CLUSTER_ID="$(kafka-storage.sh random-uuid)"
CONTROLLER_0_UUID="$(kafka-storage.sh random-uuid)"
CONTROLLER_1_UUID="$(kafka-storage.sh random-uuid)"
CONTROLLER_2_UUID="$(kafka-storage.sh random-uuid)"
```

Rode este comando para faciltar, e entao copie o resultado e copie em cada container.
```bash
echo kafka-storage.sh format --cluster-id ${CLUSTER_ID} --initial-controllers "11@kafka01:9093:${CONTROLLER_0_UUID},12@kafka02:9093:${CONTROLLER_1_UUID},13@kafka03:9093:${CONTROLLER_2_UUID}" --config /opt/kafka/config/kraft/controller.properties
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/kraft/controller.properties
```

Describe Kraft
```bash
kafka-metadata-quorum.sh --bootstrap-controller kafka01:9093 describe --status
```

Rode este comando para faciltar, e entao copie o resultado e copie em cada container.
```bash
echo kafka-storage.sh format --cluster-id ${CLUSTER_ID} --config /opt/kafka/config/kraft/broker.properties --no-initial-controllers
```

Start kafka:
```bash
kafka-server-start.sh -daemon /opt/kafka/config/kraft/broker.properties
```

Describe Kraft
```bash
kafka-metadata-quorum.sh --bootstrap-controller kafka01:9093 describe --status
```

## Agora, apenas no primeiro terminal.
### Create a topic:

```bash
  kafka-topics.sh --bootstrap-server kafka01:9092 --topic test --partitions 3 --create --replication-factor 3 --config min.insync.replicas=3
```
Describe:
```bash
kafka-topics.sh --bootstrap-server kafka01:9092 --topic test --describe
```
Produzindo mensagens
```bash
kafka-verifiable-producer.sh --bootstrap-server kafka01:9092 --max-messages 100 --topic test
```
