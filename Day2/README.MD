# Apache Kafka - Arquitetura, Zookeeper e KRaft
Fundamentos Apache Kafka na visão Admin.

O vídeo foi feito com a idéia de compartilhar o meu conhecimento adquirido, trabalhando com Kafka, para colegas de trabalho e alguns amigos.
Eu mesmo editei o vídeo, sem muito conhecimento na ferramenta.


## Comandos: 
Estou utilizando um container neste momento, indico instalar o Docker ou Docker Desktop - https://www.docker.com/products/docker-desktop/

### Criar diretório em sua máquina local e executar os comandos a partir deste diretório

``` bash
$ mkdir kafka
$ cd kafka
```

### Baixar imagem do Ubuntu
``` bash
$ docker pull ubuntu
```

### Rodando o container. segue examplos para diferentes SO:
#### No Windows CMD
``` bash
docker run --rm -it -v %cd%:/opt -p 9092:9092 ubuntu:latest
```
#### No Windows Poweshell
``` bash
docker run --rm -it -v  ${PWD}:/opt -p 9092:9092 ubuntu:latest
```
#### No Linux 
``` bash
docker run --rm -it -v $(pwd):/opt -p 9092:9092 ubuntu:latest
``` 
#### Utilizando Podman no Linux
``` bash
sudo podman run --privileged --rm -it -v $(pwd):/opt -p 9092:9092 ubuntu:latest
``` 
### Instalando pacotes
``` bash
$ apt update && apt install default-jdk wget vim jq kafkacat -y
``` 
### Baixando o Kafka
``` 
$ wget -c https://dlcdn.apache.org/kafka/3.4.0/kafka_2.13-3.4.0.tgz -O - | tar -xz

$ cd kafka_2.13-3.4.0
``` 
### Inciando Zookeeper
``` bash
bin/zookeeper-server-start.sh -daemon config/zookeeper.properties
``` 
### Iniciando o Kafka
``` bash
bin/kafka-server-start.sh -daemon config/server.properties
``` 
### Criar Topico
``` bash
bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic topico1
``` 
### Listar Topicos
``` bash
bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
``` 
### Describe
``` bash
bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic topico1
``` 

## Fatiando Vídeo

https://youtu.be/IYcp8lr8L6E

00:00 ZooKeeper

02:39 Iniciando container e instalação de Pacotes

03:42 Binários e arquivos de configuração

06:09 Iniciando ZooKeeper e Kafka

07:23 Logs

08:21 Criando Topico

09:11 Limitação ZooKeeper e KRaft

13:29 Topicos
