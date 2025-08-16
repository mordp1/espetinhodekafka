<!--
Este README documenta exemplos práticos de uso do Single Message Transform (SMT) MaskField no Kafka Connect para mascaramento de dados sensíveis em pipelines de integração. 

Inclui instruções para:
- Inicialização do ambiente Docker com Kafka Connect, MySQL e ferramentas auxiliares.
- Configuração de conectores JdbcSourceConnector e JdbcSinkConnector utilizando MaskField para mascarar campos específicos.
- Utilização do DatagenConnector para geração de dados de exemplo.
- Comandos para listar tópicos e consumir mensagens via kcat.
- Verificação de tabelas e dados no MySQL.

O MaskField SMT permite substituir valores de campos sensíveis por valores nulos ou customizados, facilitando conformidade com legislações de privacidade (LGPD, GDPR, etc.), aumentando a segurança dos dados e promovendo flexibilidade na configuração dos pipelines sem alterações no código das aplicações.
-->

# Exemplos de uso de Single Message Transforms (SMT) - MaskField

- https://docs.confluent.io/kafka-connectors/transforms/current/maskfield.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.MaskField 

O MaskField SMT é uma solução simples, declarativa e altamente utilizada para mascarar dinamicamente dados sensíveis em fluxos de integração via Kafka Connect, tornando pipelines mais seguros, flexíveis e conforme as legislações vigentes

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

Configurar o JdbcSourceConnector connector com mysql com MaskField
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

Listar Topicos kcat
```bash
docker exec kafkacat kcat -b broker:29092 -L -J | jq '.topics[].topic'|sort
```

Utilizando o kcat para consumir as mensagens: 
```bash
docker exec kafkacat kcat -b broker:29092 -t mysql-01-customers -s key=s -s value=avro -r http://schema-registry:8081
```

Vamos utilizar o DatagenConnector para gerar nossas mensagens
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

Criar JdbcSinkConnector com MaskField
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

Criar JdbcSinkConnector com MaskField
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

Verificar o nome da tabela
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "select * from \`shoe_customers\`;"
```

# O que é o MaskField?
O MaskField é um Single Message Transform (SMT) do Kafka Connect utilizado para mascarar (ofuscar ou substituir) campos sensíveis em dados que transitam entre sistemas via Kafka Connect. Com ele, é possível substituir o valor de determinados campos de registros Kafka por um valor nulo apropriado ao tipo de dado ou por uma string/customização definida por configuração. A transformação pode ser aplicada tanto à chave quanto ao valor do registro, usando as classes específicas MaskField$Key ou MaskField$Value

## Funcionamento
- Permite mascarar campos de tipos como String, Integer, Boolean, Float, Double, BigDecimal, Date, entre outros.
- Por padrão, substitui o valor do campo por “null” ou um valor equivalente ao tipo (por exemplo, "" para string, 0 para números, false para booleanos).
- É possível configurar um valor customizado para substituir, como "REDACTED", "***-***-****" ou padrões semelhantes

# Benefícios
- Privacidade e conformidade: Ajuda a garantir que dados sensíveis (como PII – informações pessoais identificáveis) não sejam expostos durante integração e processamento de dados.
- Minimiza custos de compliance: Facilita aderência a LGPD, GDPR, HIPAA, PCI-DSS, e outros requisitos de privacidade e governança.
- Flexibilidade: Pode ser facilmente aplicado e configurado em diferentes conectores e fluxos de dados sem necessidade de alterações no código das aplicações fonte ou destino.
- Reutilização: O mesmo SMT pode ser aplicado em múltiplos campos e múltiplos conectores, centralizando políticas de mascaramento
