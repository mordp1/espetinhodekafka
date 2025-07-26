<!--
# Kafka Connect SMT Examples: ValueToKey, ExtractField, and InsertField

This documentation provides step-by-step instructions and explanations for using Single Message Transforms (SMT) in Kafka Connect, focusing on the `ValueToKey`, `ExtractField`, and `InsertField` transforms. It covers:

- Starting the Kafka Connect environment using Docker Compose.
- Verifying Kafka Connect readiness and available connector plugins.
- Configuring the `JdbcSourceConnector` with MySQL as a source.
- Using `kcat` (formerly kafkacat) to inspect Kafka topics and consume messages.
- Applying the `ValueToKey` SMT to promote a field from the message value to the key.
- Chaining `ValueToKey` and `ExtractField` SMTs to extract a specific field as the message key.
- Practical examples of consuming transformed messages.
- Detailed benefits and common use cases for the `InsertField` SMT, including data enrichment, auditing, integration facilitation, and schema adaptation.

References to official documentation for further reading on `InsertField` are also provided.

This guide is intended for users looking to enrich, transform, and adapt data flowing through Kafka Connect without custom code, leveraging built-in SMTs for flexible and maintainable data pipelines.
-->

# Use Examples for Single Message Transforms (SMT) - ValueToKey and ExtractField

- https://docs.confluent.io/kafka-connectors/transforms/current/valuetokey.html
- https://docs.confluent.io/kafka-connectors/transforms/current/extractfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ValueToKey
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.ExtractField

Start Docker

```bash
docker-compose -f docker-compose.yml up -d
```

Wait for Kafka Connect to Start
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

Check Kafka Connect Plugins
```bash
curl -s http://localhost:8083/connector-plugins | jq 
```

Configure the JdbcSourceConnector with MySQL
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-jdbc-mysql-00/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-00-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false
          }'
```

Command to check if Connectors are running
```bash
curl -s "http://localhost:8083/connectors?expand=info&expand=status" | \
       jq '. | to_entries[] | [ .value.info.type, .key, .value.status.connector.state,.value.status.tasks[].state,.value.info.config."connector.class"]|join(":|:")' | \
       column -s : -t| sed 's/\"//g'| sort
```

List Topics with kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

View messages in the database
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM customers;"
```

Consume one message using kcat
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-00-customers -C -c1 -o beginning -u -q -J | jq '.'
```

Updating the JdbcSourceConnector to use the ValueToKey transform, where we will add a new key
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/source-jdbc-mysql-01/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-01-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "copyIdToKey",
          "transforms.copyIdToKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
          "transforms.copyIdToKey.fields": "id"
      }'
```

Consume One Message Using kcat
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-01-customers -C -c1 -o beginning -u -q -J | jq '.'
```

Update the JdbcSourceConnector to Use Both ValueToKey and ExtractField Transforms
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/source-jdbc-mysql-02/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-02-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist" : "customers",
          "mode":"incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "copyIdToKey,extractKeyFromStruct",
          "transforms.copyIdToKey.type": "org.apache.kafka.connect.transforms.ValueToKey",
          "transforms.copyIdToKey.fields": "id",
          "transforms.extractKeyFromStruct.type":"org.apache.kafka.connect.transforms.ExtractField$Key",
          "transforms.extractKeyFromStruct.field":"id"
      }'
```

Consume One Message Using kcat
```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t mysql-02-customers -C -c1 -o beginning -u -q -J | jq '.'
```

# Benefits of Using InsertField in Kafka Connect SMT

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html

- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField

SMT InsertField allows you to add additional fields to each message traveling through a connector in Kafka Connect, either in the value, the key, or both. It can insert values from message metadata (such as topic, partition, offset, or timestamp) or include a completely static and configurable value.

## What is ValueToKey?
ValueToKey is a Kafka Connect Single Message Transform (SMT) that allows you to set the message key based on one or more fields from the original message's value.
In many integrations, the source connector may not define the record key, or that key might not be the most useful field for downstream systems (for example, to ensure partitioning, idempotency, or joins).

- How does it work?
It copies one or more fields from the value to form the record key, overwriting the previous key.
The fields are specified using the fields configuration.

## What is ExtractField?
ExtractField is another SMT used to extract and select a specific field from a Struct in the key or value, replacing that side entirely with the extracted field's value.
It is commonly used together with `ValueToKey` to simplify the key: transforming a full struct into a primitive value.

- How does it work?
It uses the type `ExtractField$Key` (to extract from the key) or `ExtractField$Value` (to extract from the value), and the field parameter points to the desired field name.

**A common combination is to first use `ValueToKey` to set the message key and then `ExtractField` to ensure the key is a primitive value (e.g., an integer or string), which is especially useful for JDBC integrations.**

##  Most Common Use Cases
|Scenario	| Benefit| 
|---|---|
|Efficient Partitioning|	Ensure messages with the same value for "id" or another relevant field go to the same Kafka partition.|
|Preparing Data for Kafka Streams/ksqlDB |	Many stream processing and join operations require data to be properly keyed.|
|CDC and Integrations with Relational Databases	| Databases expect the primary key as the topic key for upserts/idempotency. |
| Simplifying Data for Sink Loads |	Remove nesting, making the key compatible with final systems like relational databases.|