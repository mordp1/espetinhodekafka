# Apache Kafka - Topic, Partition e Segment.
Fundamentos Apache Kafka na visão Admin.

O vídeo foi feito com a idéia de compartilhar o meu conhecimento adquirido, trabalhando com Kafka, para colegas de trabalho e alguns amigos.
Eu mesmo editei o vídeo, sem muito conhecimento na ferramenta.


Comandos: 
Estou utilizando um container neste momento, indico instalar o Docker ou Docker Desktop.

https://www.docker.com/products/docker-desktop/

## Criar Topico
```bash
$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic topico2 --partitions 4
```
## Listar Topicos
```bash
$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```
## Describe
```bash
$ bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic topico2
```
## Executar Producer
```bash
$ bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic topico1
```
### Abra outro terminal e procure seu container.
```bash
$ docker ps
ou
$ podman ps
```
## troque o NOME pelo nome do seu container
```bash
$ docker exec -ti NOME /bin/bash
```
## Executar o consumer
```bash
$ cd /opt/kafka_2.13-3.4.0
$ bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic topico1
```
## Fatiando o Vídeo

https://youtu.be/gsaEp1WQZM8

00:00 - Topicos

03:19 - Padrão de armazenamento dos segmentos do Kafka

04:52 - kafka-topics.sh

06:25 - Explicando o describe

07:15  - server.properties

12:12 - producer-console e consumer-console