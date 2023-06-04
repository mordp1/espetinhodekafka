# Apache Kafka - Entendendo replicação de partições e ISR (In-Sync Replicas)

Apache Kafka na visão Admin.

O vídeo foi feito com a idéia de compartilhar o meu conhecimento adquirido, trabalhando com Kafka, para colegas de trabalho e alguns amigos.
Eu mesmo editei o vídeo, sem muito conhecimento na ferramenta.

Entendo na pratica a replicaçãodas partições no cluster do Apache Kafka, no pequeno cluster que estou rodando via container. 

## Comandos: 
Estou utilizando um container neste momento, indico instalar o Docker ou Docker Desktop

Utilizaremos o exemplo da Conduktor.

https://www.conduktor.io/kafka/how-to-start-kafka-using-docker/

### Clone do repo
```bash
$ git clone https://github.com/conduktor/kafka-stack-docker-compose.git
$ cd kafka-stack-docker-compose
```
### Subindo 
```bash
$ docker-compose -f zk-multiple-kafka-multiple.yml up -d
```
### Conectando no shell do container kafka1
```bash
$ docker exec -it kafka1 /bin/bash
```
### Criando os 3 topicos dentro do container
```bash
$ kafka-topics --bootstrap-server kafka1:19092 --topic topic1 --create --partitions 3 --replication-factor 1

$ kafka-topics --bootstrap-server kafka1:19092 --topic topic2 --create --partitions 3 --replication-factor 2

$ kafka-topics --bootstrap-server kafka1:19092 --topic topic3 --create --partitions 3 --replication-factor 3
```
### Para executar os comandos fora do container, precisa ter os binários do Kafka:
```bash
$ wget -c https://dlcdn.apache.org/kafka/3.4.0/kafka_2.13-3.4.0.tgz -O - | tar -xz
$ cd kafka_2.13-3.4.0
```
### Comandos para cirar topicos fora do container
```bash
$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --topic topic1 --create --partitions 3 --replication-factor 1

$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --topic topic2 --create --partitions 3 --replication-factor 2

$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --topic topic3 --create --partitions 3 --replication-factor 3
```
### Remover container: 
```bash
$ docker rm -f kafka02
```
### Describe todos os topicos
```bash
$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe
```
## Fatiando o Vídeo

https://youtu.be/fiV3EOJiK-Y