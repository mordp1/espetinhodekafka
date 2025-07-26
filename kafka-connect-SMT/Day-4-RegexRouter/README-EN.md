<!--
This README.md file provides usage examples of the RegexRouter Single Message Transform (SMT) in Kafka Connect.
It includes instructions and practical examples for configuring and applying RegexRouter to Kafka topics, making it easier to dynamically route messages based on regular expressions.
-->

# Usage Examples for Single Message Transforms (SMT) - RegexRouter

- https://docs.confluent.io/kafka-connectors/transforms/current/regexrouter.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.RegexRouter

The RegexRouter is a powerful and frequently used tool in data integrations with Kafka Connect, simplifying the management, routing, and standardization of topic names in pipelines ranging from simple scenarios to robust production environments.


Start Docker
```bash
docker-compose -f docker-compose.yml up -d
```

Configure the JdbcSourceConnector with MySQL
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

Use DatagenConnector to Generate Sample Messages
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "day4-transactions",
        "quickstart": "transactions",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1"
    }'
```

List Topics with kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Consume Messages Using kcat
```bash
docker exec kafkacat kcat -b broker:29092 -t transactions -s key=s -s value=avro -r http://schema-registry:8081
```

Create JdbcSinkConnector
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"               : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                : "jdbc:mysql://mysql:3306/demo",
          "connection.user"               : "mysqluser",
          "connection.password"           : "mysqlpw",
          "topics"                        : "day4-transactions",
          "tasks.max"                     : "1",
          "auto.create"                   : "true",
          "auto.evolve"                   : "true"
        }'
```

Check the Table Name
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "select * from \`day4-transactions\`;"
```

Update the JdbcSinkConnector with RegexRouter
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"                        : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                         : "jdbc:mysql://mysql:3306/demo",
          "connection.user"                        : "mysqluser",
          "connection.password"                    : "mysqlpw",
          "topics"                                 : "day4-transactions",
          "tasks.max"                              : "4",
          "auto.create"                            : "true",
          "auto.evolve"                            : "true",
          "transforms"                             : "dropTopicPrefix",
          "transforms.dropTopicPrefix.type"        : "org.apache.kafka.connect.transforms.RegexRouter",
          "transforms.dropTopicPrefix.regex"       : "day4-(.*)",
          "transforms.dropTopicPrefix.replacement" : "$1"
        }'
```

Check the Table Name Again
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"
```

# What is RegexRouter?
RegexRouter is a Kafka Connect Single Message Transform (SMT) that lets you dynamically change the topic name of a message using a regular expression and a replacement string.
This is useful for both source and sink connectors, modifying the topic name according to the needs of your integration.

## Benefits of RegexRouter

- Topic Name Standardization:
Makes it easy to adapt Kafka topics to specific naming conventions for consumer systems or different teams, avoiding redundant topics.

- Flexible Routing:
Enables you to route messages to different topics based on patterns in the original name, supporting scenarios like multi-tenancy, sharding, or grouping by environment/application.

- Simplifies Integration with Sinks:
Downstream systems (like databases, Elasticsearch, S3) often use the Kafka topic name for table, index, or directory naming. RegexRouter allows you to adjust topic names as expected by the destination.

- Pipeline/Project Reuse:
RegexRouter lets you reuse integration pipelines and scripts by simply changing routing patterns for each environment (DEV, QA, PROD).

- Architectural Simplification:
You can consolidate or split topics according to different needs without refactoring the data source.

# Common Production Use Cases
- Adding or Removing Prefixes/Suffixes:
Companies often use prefixes like dev-, qa-, prod- on topics; RegexRouter removes or adds these prefixes when migrating data between environments or integrating with different systems.

- Integration Between Legacy and Modern Systems:
When integrating data from systems that produce topics with legacy patterns, you can update the topic names to modern standards or destination ecosystem conventions.

- Name Normalization:
Apply lowercase, replace invalid characters, or remove unnecessary strings when publishing data—useful for compatibility with systems like Elasticsearch, which restricts index names.

- Multi-company/Multi-tenant Event Routing:
In SaaS environments, RegexRouter can separate or merge events for different clients, creating dynamic topics based on client identifier or region.

- Organization for Sinks like S3:
Sink systems like S3 or BigQuery use the topic name to create folders or tables; RegexRouter is fundamental for creating hierarchies or cleaning names to meet data lake standards.


## Configuration and Usage Examples

1. Remove Prefix
```json
"transforms": "dropPrefix",
"transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.dropPrefix.regex": "soe-(.*)",
"transforms.dropPrefix.replacement": "$1"
```
Before: soe-Order → After: Order

2. Add Prefix
```json
"transforms": "AddPrefix",
"transforms.AddPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.AddPrefix.regex": ".*",
"transforms.AddPrefix.replacement": "acme_$0"
```
Before: Order → After: acme_Order

3. Remove an Intermediate Part of the Name
```json
"transforms": "RemoveString",
"transforms.RemoveString.type": "org.apache.kafka.connect.transforms.RegexRouter",
"transforms.RemoveString.regex": "(.*)Stream_(.*)",
"transforms.RemoveString.replacement": "$1$2"
```
Before: Order_Stream_Data → After: Order_Data
