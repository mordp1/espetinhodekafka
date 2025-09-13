<!--
# Kafka Connect SMT Usage Examples - TimestampRouter

This document presents practical examples of how to use Single Message Transforms (SMT) in Kafka Connect, focusing on the use of `TimestampRouter` for timestamp-based message routing. The following topics are covered:

- Initializing the Docker environment with Kafka Connect.
- Checking the status of Kafka Connect and available plugins.
- Using the DatagenConnector to generate sample messages.
- Listing Kafka topics using kcat.
- Consuming messages from topics with kcat, including Avro and Schema Registry support.
- Configuring the JdbcSinkConnector for data persistence in MySQL, demonstrating the use of the SMT `TimestampRouter` to create dynamic topics based on timestamp.
- Querying persisted data in MySQL.
- References to official documentation for the SMTs used, including InsertField and TimestampRouter.

The goal is to demonstrate how to enrich and dynamically route messages in data pipelines using Kafka Connect, making it easier to organize and partition data by date or other temporal criteria.
-->

# Examples of Using Single Message Transforms (SMT) - TimestampRouter

- https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField 

Start docker

```bash
docker-compose -f docker-compose.yml up -d
```

Wait for Kafka Connect to start up

```bash
bash -c ' \
echo -e "\n\n=============\nWaiting for Kafka Connect to start listening on localhost ⏳\n=============\n"
while [ $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) -ne 200 ] ; do
  echo -e "\t" $(date) " Kafka Connect listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) " (waiting for 200)"
  sleep 5
done
echo -e $(date) "\n\n--------------\n\o/ Kafka Connect is ready! Listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:-+-+-+-+-+
<!--
# Kafka Connect SMT - TimestampRouter: Practical Guide

This guide provides hands-on instructions for leveraging Single Message Transforms (SMT) in Kafka Connect, with an emphasis on the `TimestampRouter` transform for routing messages based on their timestamps. Covered topics include:

- Setting up Kafka Connect using Docker Compose.
- Inspecting Kafka Connect's operational status and installed plugins.
- Generating example data with the DatagenConnector.
- Listing Kafka topics with kcat.
- Consuming topic messages using kcat, including Avro and Schema Registry integration.
- Configuring JdbcSinkConnector to persist data in MySQL, showcasing dynamic topic creation with `TimestampRouter`.
- Querying stored records in MySQL.
- Reference links for official documentation on InsertField and TimestampRouter SMTs.

The aim is to illustrate how to enrich and route messages dynamically within Kafka Connect pipelines, supporting data organization and partitioning by time or other temporal attributes.
-->

# Kafka Connect SMT: TimestampRouter Usage Examples

- [InsertField SMT Documentation](https://docs.confluent.io/kafka-connectors/transforms/current/insertfield.html)
- [Kafka InsertField Transform](https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.InsertField)

## Launching the Environment

Start the required services:

```bash
docker-compose -f docker-compose.yml up -d
```

## Confirm Kafka Connect Availability

Wait for Kafka Connect to become ready:

```bash
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8083/connectors)" -eq 200 ]; do
  echo "Waiting for Kafka Connect..."
  sleep 5
done
echo "Kafka Connect is up!"
curl -s http://localhost:8083/connector-plugins | jq
```

## List Available Plugins

```bash
curl -s http://localhost:8083/connector-plugins | jq
```

## Generate Example Messages

Set up the DatagenConnector:

```bash
curl -i -X PUT -H "Content-Type:application/json" \
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

## List Kafka Topics

```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic' | sort
```

## Consume Messages with kcat

```bash
docker exec kafkacat kcat -b broker:29092 -r http://schema-registry:8081 -s key=s -s value=avro -t transactions -C -c1 -o beginning -u -q -J | jq '.'
```

## Configure JdbcSinkConnector with TimestampRouter

```bash
curl -i -X PUT -H "Content-Type:application/json" \
  http://localhost:8083/connectors/sink-jdbc-mysql-00/config \
  -d '{
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "connection.url": "jdbc:mysql://mysql:3306/demo",
    "connection.user": "mysqluser",
    "connection.password": "mysqlpw",
    "topics": "transactions",
    "tasks.max": "1",
    "auto.create": "true",
    "transforms": "addTimestampToTopic",
    "transforms.addTimestampToTopic.type": "org.apache.kafka.connect.transforms.TimestampRouter",
    "transforms.addTimestampToTopic.topic.format": "${topic}_${timestamp}",
    "transforms.addTimestampToTopic.timestamp.format": "YYYY-MM-dd"
  }'
```

## Query Data in MySQL

```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES;"
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM \`transactions_2025-09-13\`;"
```

# Why Use TimestampRouter in Kafka Connect SMT?

- **Temporal Data Organization:** Automatically routes records to topics named by date/time, simplifying time-based partitioning.
- **Easier Data Management:** Enables straightforward retention, archival, and deletion of old data by topic.
- **Destination Compatibility:** Many sinks (e.g., Elasticsearch, databases) use topic names for index/table names; TimestampRouter helps encode time granularity in those names.
- **Flexible Configuration:** Customize timestamp and topic formats using Java date patterns.
- **No Producer Changes Needed:** All transformations occur within Kafka Connect, requiring no changes to producing applications.

- [TimestampRouter SMT Documentation](https://docs.confluent.io/kafka-connectors/transforms/current/timestamprouter.html)
- [Kafka TimestampRouter Transform](https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.TimestampRouter)
- [Confluent Demo - kafka-connect-single-message-transforms](https://github.com/confluentinc/demo-scene/blob/master/kafka-connect-single-message-transforms/day7.adoc)