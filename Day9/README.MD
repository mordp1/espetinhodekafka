# Kafka Connect - FileStream produzindo mensagens a partir de um arquivo local.

Fundamentos Apache Kafka na visão Admin.

O vídeo foi feito com a idéia de compartilhar o meu conhecimento adquirido, trabalhando com Kafka, para colegas de trabalho e alguns amigos.
Eu mesmo editei o vídeo, sem muito conhecimento na ferramenta.

Entendo na pratica o Kafka Connect, configurando um connector FileStream para que possa ler um arquivo local e produzir mensagens no topico do Kafka

## Comandos: 
Estou utilizando um container neste momento, indico instalar o Docker ou Docker Desktop

## Kafkacat: 

https://github.com/edenhill/kcat
``` bash
$ apt-get install kafkacat
```
## Utilizaremos o exemplo da Conduktor.

https://www.conduktor.io/kafka/how-to-start-kafka-using-docker/

### Clone do repo
``` bash
$ git clone https://github.com/conduktor/kafka-stack-docker-compose.git
$ cd kafka-stack-docker-compose
```
#### Edite o zk-multiple-kafka-multiple.yml e adicione ao final do arquivo:
``` YAML
  kafka-connect:
    image: confluentinc/cp-kafka-connect:7.3.2
    hostname: kafka-connect
    container_name: kafka-connect
    ports:
      - "8083:8083"
    environment:
      CONNECT_REST_PORT: 8083
    command:
      - bash
      - -c
      - |
        echo "Installing connector plugins"
        sleep infinity
 ``` 
### Subindo 
``` bash
$ docker-compose -f zk-multiple-kafka-multiple.yml up -d
``` 
### Crie um novo topico que será usado para produzirmos as mensagens.
``` bash
$ docker exec -it kafka1 kafka-topics --bootstrap-server kafka1:19092 --topic connect-test --create --partitions 3 --replication-factor 3
```
### Crie o config.properties com seguinte conteúdo:
``` bash
$ cat << EOF> config.properties 
bootstrap.servers=kafka1:19092
key.converter=org.apache.kafka.connect.json.JsonConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
key.converter.schemas.enable=true
value.converter.schemas.enable=true
offset.storage.file.filename=/tmp/connect.offsets
offset.flush.interval.ms=10000
plugin.path=/usr/share/filestream-connectors
EOF
```
### Crie o connect-file-source.properties com seguinte conteúdo:
``` bash
$ cat << EOF> connect-file-source.properties
name=local-file-source
connector.class=FileStreamSource
tasks.max=1
file=/tmp/test.txt
topic=connect-test
EOF
``` 
### Agora crie um arquivo em /tmp/test.txt para que o connector possa ler e produzir a mensagem
``` bash
cat <<EOF> 
teste1
teste2
teste3
EOF
```
### Se você não criou dentro do container, basta copiar os 3 arquivos para dentro do container
``` bash
$ docker cp connect-file-source.properties kafka-connect:/tmp
$ docker cp config.properties kafka-connect:/tmp
$ docker cp test.txt kafka-connect:/tmp
``` 
### Abra um novo terminal e inicie o Kafka Connect:
``` bash
$ docker exec -ti kafka-connect connect-standalone /tmp/config.properties /tmp/connect-file-source.properties
``` 
### Abra um novo terminal e faça o consumo das mensagens:
``` bash
$ docker exec -it kafka1 kafka-console-consumer --bootstrap-server localhost:19092 --topic connect-test --from-beginning
``` 
### Ou pode ser utilizado o kafkacat da maquina local:
``` bash
$ kafkacat -C -b localhost:9092 -t connect-test
``` 
### Você pode adicionar novas linhas no arquivo e ver ele sendo processado

``` bash
$ docker exec -it kafka1 echo teste4 >> /tmp/test.txt
```

### Derrubando todos os containers:
``` bash
$ docker-compose -f zk-multiple-kafka-multiple.yml down
``` 

## Fatiando o Vídeo

https://youtu.be/hdC5oMpgRlc