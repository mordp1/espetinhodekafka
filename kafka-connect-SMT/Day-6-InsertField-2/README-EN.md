<!--
This README documents the use of Kafka Connect for data integration between Kafka and other systems, including MySQL and local files. The main topics covered are:

Checking the available plugins in Kafka Connect.

Using the Datagen Connector to generate mock messages in the transactions topic.

Consuming Kafka messages using kcat, with an option to visualize via VisiData.

Configuring the JdbcSinkConnector to persist data from the transactions topic into a MySQL table, including data query commands.

Alternative method for data persistence to a text file using the FileStreamSinkConnector.

Command to list and check the status of configured connectors.

Examples of using Single Message Transforms (SMTs) to add and format timestamp fields in messages before persisting them to MySQL or a file.

These examples facilitate understanding and practice with data integration using Kafka Connect, demonstrating steps from generation through consumption and persistence of data, including intermediate transformations.
-->

# Use Examples for Single Message Transforms (SMT) - InsertField (timestamp):

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField 

Start Docker

```bash
docker-compose -f docker-compose.yml up -d
```

Check Kafka until to start up

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

Check the plugins of Kafka Connect

```bash
curl -s http://localhost:8083/connector-plugins | jq 
```

We will use the `DatagenConnector` to generate our messages with `InsertField$Value`

```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "transactions",
        "quickstart": "transactions",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1",
        "transforms"                                : "insertStaticField1,insertStaticField2",
        "transforms.insertStaticField1.type"        : "org.apache.kafka.connect.transforms.InsertField$Value",
        "transforms.insertStaticField1.static.field": "sourceSystem",
        "transforms.insertStaticField1.static.value": "NeverGonna",
        "transforms.insertStaticField2.type"        : "org.apache.kafka.connect.transforms.InsertField$Value",
        "transforms.insertStaticField2.static.field": "ingestAgent",
        "transforms.insertStaticField2.static.value": "GiveYouUp"
    }'
```

List Topics with kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Consuming messages with Kcat: 

```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t transactions -C -c1 -o beginning -u -q -J | jq '.'
```

Configure the JdbcSinkConnector connector with MySQL and `InsertField$Value`

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
          "transforms"                                : "insertPartition,insertOffset,insertTopic",
          "transforms.insertPartition.type"           : "org.apache.kafka.connect.transforms.InsertField$Value",
          "transforms.insertPartition.partition.field": "kafkaPartition",
          "transforms.insertOffset.type"              : "org.apache.kafka.connect.transforms.InsertField$Value",
          "transforms.insertOffset.offset.field"      : "kafkaOffset",
          "transforms.insertTopic.type"               : "org.apache.kafka.connect.transforms.InsertField$Value",
          "transforms.insertTopic.topic.field"        : "kafkaTopic"          
        }'
```

Check messages on DB

```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM transactions;"
```


# Benefits of Using InsertField in Kafka Connect SMT

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html

- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField

SMT InsertField allows you to add additional fields to each message traveling through a connector in Kafka Connect, either in the value, the key, or both. It can insert values from message metadata (such as topic, partition, offset, or timestamp) or include a completely static and configurable value.

## Why Use InsertField
- Data Enrichment: You can enrich the messages by adding important contextual information before the data is sent to the target system, without changing connectors or implementing external logic.

- Standardization and Auditing: Adding fields like timestamp, topic name, partition or other metadata makes it easier to track, audit, and standardize entries in databases, data lakes, analytic systems, etc.

- Ease of Integration: Target systems often require extra fields (such as identifiers, origin, or processing dates) that are absent in the original data – InsertField meets this need without modifying the source application or data flow.

- Speed and Simplicity: Everything is handled through configuration, removing the need to develop, maintain, and version custom code for simple transformations.

## Common Use Cases
- Adding Timestamp Fields: Insert a field with the message processing timestamp when exporting data to storage systems, like SQL databases or S3 – useful for tracking when data was ingested or exported.

- Including Kafka Metadata: Add information such as topic name, partition, and offset to each record, facilitating investigations, debugging, and later analysis.

- Source Tagging: Include a static field such as "source": "Kafka Connect" for pipelines integrating data from multiple sources.

- Time-To-Live Configuration: Insert a TTL (Time To Live) field in platforms like Cosmos DB to control how long each exported record lives.

- Facilitating UPSERT Processes: Add an auxiliary field as an artificial unique key when source data lacks a natural unique identifier for upsert operations in relational databases.

- Schema Adaptation: When the sink system requires certain mandatory fields, InsertField makes sure all records include them, even if they weren't in the source.