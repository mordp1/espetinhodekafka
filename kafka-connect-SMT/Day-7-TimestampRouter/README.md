<!--
# Documentação de Exemplos de Uso do Kafka Connect SMT - TimestampRouter

Este documento apresenta exemplos práticos de como utilizar Single Message Transforms (SMT) no Kafka Connect, com foco no uso do `TimestampRouter` para roteamento de mensagens baseado em timestamp. São abordados os seguintes tópicos:

- Inicialização do ambiente Docker com Kafka Connect.
- Verificação do estado do Kafka Connect e dos plugins disponíveis.
- Utilização do DatagenConnector para geração de mensagens de exemplo.
- Listagem de tópicos Kafka utilizando kcat.
- Consumo de mensagens dos tópicos com kcat, incluindo suporte a Avro e Schema Registry.
- Configuração do JdbcSinkConnector para persistência de dados no MySQL, demonstrando o uso do SMT `TimestampRouter` para criar tópicos dinâmicos baseados em timestamp.
- Exemplos de consulta aos dados persistidos no MySQL.
- Referências para documentação oficial dos SMTs utilizados, incluindo InsertField e TimestampRouter.

O objetivo é demonstrar como enriquecer e rotear mensagens dinamicamente em pipelines de dados utilizando Kafka Connect, facilitando a organização e particionamento dos dados por data ou outros critérios temporais.
-->

# Exemplos de uso de Single Message Transforms (SMT) - TimestampRouter

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField 

Iniciar docker

```bash
docker-compose -f docker-compose.yml up -d
```

Esperar Kafka Connect to start up

```bash
bash -c ' \
echo -e "\n\n=============\nWaiting for Kafka Connect to start listening on localhost ⏳\n=============\n"
while [ $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) -ne 200 ] ; do
  echo -e "\t" $(date) " Kafka Connect listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) " (waiting for 200)"
  sleep 5
done
echo -e $(date) "\n\n--------------\n\o/ Kafka Connect is ready! Listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) "\n--------------\n"
curl -s http://localhost:8083/connector-plugins | jq
'
```

Verificar os plugins do Kafka Connect

```bash
curl -s http://localhost:8083/connector-plugins | jq 
```

Vamos utilizar o DatagenConnector para gerar nossas mensagens

```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "transactions",
        "quickstart": "transactions",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1"
    }'
```

Listar Topicos kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Utilizando o kcat para consumir as mensagens: 

```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t transactions -C -c1 -o beginning -u -q -J | jq '.'
```

Configurar o JdbcSinkConnector connector com mysql

```bash
curl -i -X PUT "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-00/config \
    -d '{
          "connector.class"     : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"      : "jdbc:mysql://mysql:3306/demo",
          "connection.user"     : "mysqluser",
          "connection.password" : "mysqlpw",
          "topics"              : "transactions",
          "tasks.max"           : "1",
          "auto.create"         : "true",
          "transforms"                                     : "addTimestampToTopic",
          "transforms.addTimestampToTopic.type"            : "org.apache.kafka.connect.transforms.TimestampRouter",
          "transforms.addTimestampToTopic.topic.format"    : "${topic}_${timestamp}",
          "transforms.addTimestampToTopic.timestamp.format": "YYYY-MM-dd"
        }'
```


```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-01/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "transactions.json",
        "quickstart": "transactions",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1",
        "key.converter": "org.apache.kafka.connect.json.JsonConverter",
        "key.converter.schemas.enable": "false",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false"
    }'
```


```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day7-00/config \
    -d '{
          "connector.class"                                                 : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                                                  : "jdbc:mysql://mysql:3306/demo",
          "connection.user"                                                 : "mysqluser",
          "connection.password"                                             : "mysqlpw",
          "topics"                                                          : "transactions.json",
          "tasks.max"                                                       : "1",
          "auto.create"                                                     : "true",
          "auto.evolve"                                                     : "true",
          "transforms"                                                      : "addTimestampToTopicFromField",
          "transforms.addTimestampToTopicFromField.type"                    : "io.confluent.connect.transforms.MessageTimestampRouter",
          "transforms.addTimestampToTopicFromField.message.timestamp.keys"  : "txn_date",
          "transforms.addTimestampToTopicFromField.message.timestamp.format": "EEE MMM dd HH:mm:ss zzz yyyy",
          "transforms.addTimestampToTopicFromField.topic.format"            : "${topic}_${timestamp}",
          "transforms.addTimestampToTopicFromField.topic.timestamp.format"  : "YYYY-MM-dd",
          "key.converter": "org.apache.kafka.connect.json.JsonConverter",
          "key.converter.schemas.enable": "false",
          "value.converter": "org.apache.kafka.connect.json.JsonConverter",
          "value.converter.schemas.enable": "false"
        }'
```

Podemos ver as mensagens no banco

```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES;"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "select * from \`transactions_2025-08-27\`;"
```


# Benefícios de Utilizar o TimestampRouter no Kafka Connect SMT

Organização temporal dos dados: Permite que os dados sejam automaticamente roteados para tópicos com base na data/hora, facilitando o particionamento por tempo.

Facilita a gestão e limpeza de dados: Com tópicos organizados por períodos (mês, dia), torna-se mais simples realizar operações de retenção, arquivamento e exclusão de dados antigos.

Compatibilidade com sistemas de destino: Muitos sinks (exemplo: Elasticsearch, bancos de dados) utilizam o nome do tópico para determinar o nome do índice ou tabela. O TimestampRouter ajuda a refletir a granularidade temporal no nome desses destinos.

Configuração flexível: O formato do timestamp e do nome do tópico pode ser personalizado usando padrões de formatação baseados em java.text.SimpleDateFormat.

Simplicidade e eficiência: Não requer alterações na aplicação produtora, pois a transformação acontece no pipeline do Kafka Connect.

- https://docs.confluent.io/kafka-connectors/transforms/current/timestamprouter.html

- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.TimestampRouter