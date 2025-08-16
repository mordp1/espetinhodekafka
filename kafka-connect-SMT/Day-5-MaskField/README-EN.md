<!-- 
This README documents practical examples of using the Single Message Transform (SMT) MaskField in Kafka Connect for masking sensitive data in integration pipelines. It includes instructions for: 

- Initializing the Docker environment with Kafka Connect, MySQL, and auxiliary tools. 
- Configuring JdbcSourceConnector and JdbcSinkConnector connectors using MaskField to mask specific fields. 
- Using DatagenConnector to generate sample data. 
- Commands to list topics and consume messages via kcat. 
- Verifying tables and data in MySQL. 

The MaskField SMT allows you to replace sensitive field values with null or customized values, facilitating compliance with privacy regulations (LGPD, GDPR, etc.), increasing data security, and enabling flexible pipeline configuration without changes to application code. 
-->

# Examples of Single Message Transforms (SMT) - MaskField Usage

- https://docs.confluent.io/kafka-connectors/transforms/current/maskfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.MaskField 

The MaskField SMT is a simple, declarative, and widely used solution to dynamically mask sensitive data in integration flows via Kafka Connect, making pipelines more secure, flexible, and compliant with current regulations.

Starting Docker
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
echo -e $(date) "\n\n--------------\n\o/ Kafka Connect is ready! Listener HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://localhost:8083/connectors) "\n--------------\n"
curl -s http://localhost:8083/connector-plugins | jq
'
```

Configure the JdbcSourceConnector connector with MySQL using MaskField
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-jdbc-mysql-01/config \
    -d '{
          "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
          "connection.url": "jdbc:mysql://mysql:3306/demo",
          "connection.user": "mysqluser",
          "connection.password": "mysqlpw",
          "topic.prefix": "mysql-01-",
          "poll.interval.ms": 1000,
          "tasks.max":1,
          "table.whitelist": "customers",
          "mode": "incrementing",
          "incrementing.column.name": "id",
          "validate.non.null": false,
          "transforms": "FavAnimal",
          "transforms.FavAnimal.type": "org.apache.kafka.connect.transforms.MaskField$Value",
          "transforms.FavAnimal.fields": "fav_animal",
          "transforms.FavAnimal.replacement": "xxx"
          }'
```

List Topics with kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Using kcat to consume messages:
```bash
docker exec kafkacat kcat -b broker:29092 -t mysql-01-customers -s key=s -s value=avro -r http://schema-registry:8081
```

We will use the DatagenConnector to generate our messages
```bash
curl -i -X PUT -H  "Content-Type:application/json" \
    http://localhost:8083/connectors/source-voluble-datagen-00/config \
    -d '{
        "connector.class": "io.confluent.kafka.connect.datagen.DatagenConnector",
        "kafka.topic": "shoe_customers",
        "quickstart": "shoe_customers",
        "value.converter.schemas.enable": "false",
        "max.interval": 1000,
        "tasks.max": "1"
    }'
```

Create JdbcSinkConnector with MaskField
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"                    : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                     : "jdbc:mysql://mysql:3306/demo",
          "connection.user"                    : "mysqluser",
          "connection.password"                : "mysqlpw",
          "topics"                             : "shoe_customers",
          "tasks.max"                          : "1",
          "auto.create"                        : "true",
          "auto.evolve"                        : "true",
          "transforms"                         : "maskPhone,maskEmail",
          "transforms.maskPhone.type"        : "org.apache.kafka.connect.transforms.MaskField$Value",
          "transforms.maskPhone.fields"      : "phone",
          "transforms.maskPhone.replacement" : "+0-000-000-0000",
          "transforms.maskEmail.type"        : "org.apache.kafka.connect.transforms.MaskField$Value",
          "transforms.maskEmail.fields"      : "email",
          "transforms.maskEmail.replacement" : "xxx@xxx.com"
        }'
```

Create JdbcSinkConnector with MaskField
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day4-transactions-00/config \
    -d '{
          "connector.class"                    : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                     : "jdbc:mysql://mysql:3306/demo",
          "connection.user"                    : "mysqluser",
          "connection.password"                : "mysqlpw",
          "topics"                             : "shoe_customers",
          "tasks.max"                          : "1",
          "auto.create"                        : "true",
          "auto.evolve"                        : "true",
          "transforms"                         : "maskField",
          "transforms.maskField.type"          : "org.apache.kafka.connect.transforms.MaskField$Value",
          "transforms.maskField.fields"        : "phone,email"
        }'
```

Check the table name
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "select * from \`shoe_customers\`;"
```

# What is MaskField?
MaskField is a Single Message Transform (SMT) in Kafka Connect used to mask (obfuscate or replace) sensitive fields in data flowing between systems via Kafka Connect. It allows replacing the value of specific fields in Kafka records with a null value appropriate to the data type or a custom string/value defined via configuration. The transformation can be applied to either the record key or value using the specific classes MaskField$Key or MaskField$Value.

## How it works
- Allows masking fields of types such as String, Integer, Boolean, Float, Double, BigDecimal, Date, among others.
- By default, it replaces the field value with null or a type-appropriate equivalent (e.g., "" for strings, 0 for numbers, false for booleans).
- It is possible to configure a custom replacement value, such as "REDACTED", "***-***-****", or similar patterns.

# Benefits
- Privacy and compliance: Helps ensure that sensitive data (such as PII – personally identifiable information) is not exposed during data integration and processing.
- Minimizes compliance costs: Facilitates adherence to LGPD, GDPR, HIPAA, PCI-DSS, and other privacy and governance requirements.
- Flexibility: Can be easily applied and configured across different connectors and data flows without needing changes in source or destination application code.
- Reusability: The same SMT can be applied to multiple fields and connectors, centralizing data masking policies.