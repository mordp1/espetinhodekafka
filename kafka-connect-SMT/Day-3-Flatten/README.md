<!--
# Documentação de Exemplo de Flatten SMT do Kafka Connect

Este guia demonstra como usar a Transformação de Mensagem Única (SMT) `Flatten` do Kafka Connect para manipular estruturas de dados aninhadas (STRUCT) ao coletar dados de tópicos do Kafka para um banco de dados relacional usando o Conector de Coletor JDBC.

## Etapas Abordadas

1. **Iniciando o Ambiente**: Instruções para iniciar os contêineres Docker necessários para Kafka, Kafka Connect, ksqlDB e MySQL.
2. **Aguardando Serviços**: Scripts para aguardar que o Kafka Connect e o ksqlDB estejam totalmente disponíveis antes de prosseguir.
3. **Criando Fluxos**: Comandos SQL para criar tópicos do Kafka com campos STRUCT aninhados usando ksqlDB.
4. **Preenchendo Dados**: Inserções SQL de exemplo para preencher os tópicos com dados aninhados de amostra.
5. **Configurando o Conector de Coletor JDBC**:
- Configuração inicial sem SMT, demonstrando o erro quando campos STRUCT estão presentes.
- Explicação do erro: O Conector de Coletor JDBC não consegue mapear tipos STRUCT diretamente para colunas SQL.
6. **Aplicando o Flatten SMT**:
- Como configurar o conector com o SMT `Flatten` para nivelar campos STRUCT aninhados em colunas planas, tornando-os compatíveis com bancos de dados relacionais.
- Etapas de verificação para verificar a criação de tabelas e a inserção de dados no MySQL.
7. **Configuração de Chave Primária**:
- Como definir a chave de registro do Kafka como a chave primária na tabela SQL usando `pk.mode` e `pk.fields`.
- Exemplo de configuração para lidar com chaves e nivelamento de valores simultaneamente.

## Conceitos Principais

- **Mapeamento de STRUCT para SQL**: Bancos de dados relacionais exigem esquemas planos; campos STRUCT aninhados devem ser nivelados antes do nivelamento.

- **SMT Flatten**: A SMT `Flatten` transforma campos aninhados em campos planos usando um delimitador, permitindo a compatibilidade com bancos de dados SQL.
- **Manipulação de Chave Primária**: A configuração adequada das chaves primárias garante upserts corretos e exclusividade na tabela SQL de destino.

## Solução de Problemas

- Se você encontrar erros sobre tipos STRUCT não mapeáveis, certifique-se de que a SMT `Flatten` esteja configurada corretamente.
- Sempre verifique o status do conector e os logs de tarefas para solução de problemas.

-->
# Exemplos de uso de Single Message Transforms (SMT) - Flatten

- https://docs.confluent.io/kafka-connectors/transforms/current/flatten.html
- https://kafka.apache.org/documentation/#org.apache.kafka.connect.transforms.Flatten

O Flatten SMT é ideal para transformar mensagens Kafka com estruturas aninhadas em mensagens planas, facilitando a integração com uma variedade de sistemas que não suportam campos compostos ou aninhados

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

Comando para esperar o ksqldb-server terminar de iniciar e entao abrir um terminal para nos
```bash
docker exec -it ksqldb-server bash -c 'echo -e "\n\n⏳ Waiting for ksqldb-server to be available before launching CLI\n"; while : ; do curl_status=$(curl -s -o /dev/null -w %{http_code} http://ksqldb-server:8088/info) ; echo -e $(date) " ksqldb-server server listener HTTP state: " $curl_status " (waiting for 200)" ; if [ $curl_status -eq 200 ] ; then  break ; fi ; sleep 5 ; done ; ksql http://ksqldb-server:8088'
```

Create a stream:
```SQL
CREATE STREAM CUSTOMERS1 (ID BIGINT KEY, FULL_NAME VARCHAR, ADDRESS STRUCT<STREET VARCHAR, CITY VARCHAR, COUNTY_OR_STATE VARCHAR, ZIP_OR_POSTCODE VARCHAR>)
                  WITH (KAFKA_TOPIC='customers1',
                        VALUE_FORMAT='AVRO',
                        REPLICAS=1,
                        PARTITIONS=4);
```

Populate the topic with some nested data
```SQL
INSERT INTO CUSTOMERS1 VALUES(1,'Opossum, american virginia',STRUCT(STREET:='20 Acker Terrace', CITY:='Lynchburg', COUNTY_OR_STATE:='Virginia', ZIP_OR_POSTCODE:='24515'));
INSERT INTO CUSTOMERS1 VALUES(2,'Skua, long-tailed',STRUCT(STREET:='7 Laurel Terrace', CITY:='Manassas', COUNTY_OR_STATE:='Virginia', ZIP_OR_POSTCODE:='22111'));
INSERT INTO CUSTOMERS1 VALUES(3,'Red deer',STRUCT(STREET:='53 Basil Terrace', CITY:='Lexington', COUNTY_OR_STATE:='Kentucky', ZIP_OR_POSTCODE:='40515'));
INSERT INTO CUSTOMERS1 VALUES(4,'Vervet monkey',STRUCT(STREET:='7615 Brown Park', CITY:='Chicago', COUNTY_OR_STATE:='Illinois', ZIP_OR_POSTCODE:='60681'));
INSERT INTO CUSTOMERS1 VALUES(5,'White spoonbill',STRUCT(STREET:='7 Fulton Parkway', CITY:='Asheville', COUNTY_OR_STATE:='North Carolina', ZIP_OR_POSTCODE:='28805'));
INSERT INTO CUSTOMERS1 VALUES(6,'Laughing kookaburra',STRUCT(STREET:='84 Monument Alley', CITY:='San Jose', COUNTY_OR_STATE:='California', ZIP_OR_POSTCODE:='95113'));
INSERT INTO CUSTOMERS1 VALUES(7,'Fox, bat-eared',STRUCT(STREET:='2946 Daystar Drive', CITY:='Jamaica', COUNTY_OR_STATE:='New York', ZIP_OR_POSTCODE:='11431'));
INSERT INTO CUSTOMERS1 VALUES(8,'Sun gazer',STRUCT(STREET:='61 Lakewood Gardens Parkway', CITY:='Pensacola', COUNTY_OR_STATE:='Florida', ZIP_OR_POSTCODE:='32590'));
INSERT INTO CUSTOMERS1 VALUES(9,'American bighorn sheep',STRUCT(STREET:='326 Sauthoff Crossing', CITY:='San Antonio', COUNTY_OR_STATE:='Texas', ZIP_OR_POSTCODE:='78296'));
INSERT INTO CUSTOMERS1 VALUES(10,'Greater rhea',STRUCT(STREET:='97 Morning Way', CITY:='Charleston', COUNTY_OR_STATE:='West Virginia', ZIP_OR_POSTCODE:='25331'));
```

Criar nosso connector JdbcSinkConnector
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day3-customers-00/config \
    -d '{
          "connector.class"               : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                : "jdbc:mysql://mysql:3306/demo",
          "connection.user"               : "mysqluser",
          "connection.password"           : "mysqlpw",
          "topics"                        : "customers1",
          "tasks.max"                     : "1",
          "auto.create"                   : "true",
          "auto.evolve"                   : "true"
        }'
```

Vamos verificar que nossa task falhou
```bash
curl -s "http://localhost:8083/connectors?expand=info&expand=status" | \
       jq '. | to_entries[] | [ .value.info.type, .key, .value.status.connector.state,.value.status.tasks[].state,.value.info.config."connector.class"]|join(":|:")' | \
       column -s : -t| sed 's/\"//g'| sort

curl -s "http://localhost:8083/connectors/sink-jdbc-mysql-day3-customers-00/tasks/0/status" | jq
```

Error Message
```ERROR
(STRUCT) type doesn't have a mapping to the SQL database column type
```

Esse erro acontece quando você utiliza o Kafka Connect JDBC Sink Connector para enviar dados do Kafka para um banco relacional (como MySQL, PostgreSQL ou Oracle), mas a mensagem contém campos do tipo STRUCT (estrutura aninhada) e o conector não sabe converter esse tipo para uma coluna simples no banco de dados. Os bancos SQL esperam campos “planos” (tipos primitivos ou strings), não estruturas aninhadas.

Entao, vamo utilizar o SMT Flatten para resolver isso.
```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day3-customers-00/config \
    -d '{
          "connector.class"               : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                : "jdbc:mysql://mysql:3306/demo",
          "connection.user"               : "mysqluser",
          "connection.password"           : "mysqlpw",
          "topics"                        : "customers1",
          "tasks.max"                     : "1",
          "auto.create"                   : "true",
          "auto.evolve"                   : "true",
          "transforms"                    : "flatten",
          "transforms.flatten.type"       : "org.apache.kafka.connect.transforms.Flatten$Value",
          "transforms.flatten.delimiter"  : "_"
        }'
```

Verificar se ele criou a tabela:
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"
```

Select na tabela
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "DESCRIBE customers1;"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM customers1;"
```

Vamos agora adicionar as Key como Primary Key da nossa tabela

```bash
docker exec -it ksqldb-server bash -c ksql http://ksqldb-server:8088
```

Create a stream:
```SQL
CREATE STREAM CUSTOMERS2 (ID BIGINT KEY, FULL_NAME VARCHAR, ADDRESS STRUCT<STREET VARCHAR, CITY VARCHAR, COUNTY_OR_STATE VARCHAR, ZIP_OR_POSTCODE VARCHAR>)
                  WITH (KAFKA_TOPIC='customers2',
                        VALUE_FORMAT='AVRO',
                        REPLICAS=1,
                        PARTITIONS=4);
```

Populate the topic with some nested data
```SQL
INSERT INTO CUSTOMERS2 VALUES(1,'Opossum, american virginia',STRUCT(STREET:='20 Acker Terrace', CITY:='Lynchburg', COUNTY_OR_STATE:='Virginia', ZIP_OR_POSTCODE:='24515'));
INSERT INTO CUSTOMERS2 VALUES(2,'Skua, long-tailed',STRUCT(STREET:='7 Laurel Terrace', CITY:='Manassas', COUNTY_OR_STATE:='Virginia', ZIP_OR_POSTCODE:='22111'));
INSERT INTO CUSTOMERS2 VALUES(3,'Red deer',STRUCT(STREET:='53 Basil Terrace', CITY:='Lexington', COUNTY_OR_STATE:='Kentucky', ZIP_OR_POSTCODE:='40515'));
INSERT INTO CUSTOMERS2 VALUES(4,'Vervet monkey',STRUCT(STREET:='7615 Brown Park', CITY:='Chicago', COUNTY_OR_STATE:='Illinois', ZIP_OR_POSTCODE:='60681'));
INSERT INTO CUSTOMERS2 VALUES(5,'White spoonbill',STRUCT(STREET:='7 Fulton Parkway', CITY:='Asheville', COUNTY_OR_STATE:='North Carolina', ZIP_OR_POSTCODE:='28805'));
INSERT INTO CUSTOMERS2 VALUES(6,'Laughing kookaburra',STRUCT(STREET:='84 Monument Alley', CITY:='San Jose', COUNTY_OR_STATE:='California', ZIP_OR_POSTCODE:='95113'));
INSERT INTO CUSTOMERS2 VALUES(7,'Fox, bat-eared',STRUCT(STREET:='2946 Daystar Drive', CITY:='Jamaica', COUNTY_OR_STATE:='New York', ZIP_OR_POSTCODE:='11431'));
INSERT INTO CUSTOMERS2 VALUES(8,'Sun gazer',STRUCT(STREET:='61 Lakewood Gardens Parkway', CITY:='Pensacola', COUNTY_OR_STATE:='Florida', ZIP_OR_POSTCODE:='32590'));
INSERT INTO CUSTOMERS2 VALUES(9,'American bighorn sheep',STRUCT(STREET:='326 Sauthoff Crossing', CITY:='San Antonio', COUNTY_OR_STATE:='Texas', ZIP_OR_POSTCODE:='78296'));
INSERT INTO CUSTOMERS2 VALUES(10,'Greater rhea',STRUCT(STREET:='97 Morning Way', CITY:='Charleston', COUNTY_OR_STATE:='West Virginia', ZIP_OR_POSTCODE:='25331'));
```

```bash
curl -i -X PUT -H "Accept:application/json" \
    -H  "Content-Type:application/json" http://localhost:8083/connectors/sink-jdbc-mysql-day3-customers-02/config \
    -d '{
          "connector.class"               : "io.confluent.connect.jdbc.JdbcSinkConnector",
          "connection.url"                : "jdbc:mysql://mysql:3306/demo",
          "connection.user"               : "mysqluser",
          "connection.password"           : "mysqlpw",
          "topics"                        : "customers2",
          "tasks.max"                     : "1",
          "auto.create"                   : "true",
          "auto.evolve"                   : "true",
          "transforms"                    : "flatten",
          "transforms.flatten.type"       : "org.apache.kafka.connect.transforms.Flatten$Value",
          "transforms.flatten.delimiter"  : "_",
          "pk.mode"                       : "record_key",
          "pk.fields"                     : "id",
          "key.converter"                 : "org.apache.kafka.connect.converters.LongConverter"
        }'
```

Verificar se ele criou a tabela:
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SHOW TABLES"
```

Select na tabela
```bash
docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "DESCRIBE customers2;"

docker exec -it mysql mysql -u mysqluser -pmysqlpw demo -e "SELECT * FROM customers2;"
```

# O que é o Kafka Connect Flatten SMT?

O Flatten SMT (Single Message Transform) do Kafka Connect é uma transformação usada para “achatar” estruturas de dados aninhadas em mensagens, convertendo campos internos (por exemplo, objetos ou structs) em campos “flat” (na mesma profundidade), concatenando os nomes de cada nível com um delimitador configurável.

## Por que utilizar o Flatten SMT?
- Facilita integração com bancos de dados relacionais ou sistemas que não suportam dados aninhados.
- Torna os dados mais simples de manipular em sistemas externos, como SQL, BI e ferramentas de ETL.
- Elimina múltiplos níveis de aninhamento, tornando o mapeamento de campos mais direto e previsível.

## Como funciona o Flatten SMT?

Exemplo de mensagem com estrutura aninhada:
```JSON
{
  "content": {
    "id": 42,
    "name": {
      "first": "David",
      "middle": null,
      "last": "Wong"
    }
  }
}
```
Após aplicar o Flatten SMT:
```JSON
{
  "content.id": 42,
  "content.name.first": "David",
  "content.name.middle": null,
  "content.name.last": "Wong"
}
```

O delimitador padrão é o ponto (.), mas pode ser alterado para underline (_) ou outro caractere, especialmente ao trabalhar com schemas Avro.

## Limitações
- Arrays (listas) NÃO são achatados; permanecem como estão.
- Não recomendado para mensagens com muitas camadas aninhadas e campos com nomes potencialmente conflitantes.
- Em schemas Avro, o delimitador ponto (.) não é permitido; deve-se usar transforms.flatten.delimiter: "_".

## Casos de uso comuns

| Caso de Uso | Beneficios |
|---|---|
| Integrar com JDBC Sink Connector | Facilita inserção em tabelas SQL planas.|
| Envio para ferramentas BI/ETL | Permite leitura e transformação simples de dados.|
| Transformação de eventos complexos | Padroniza eventos de diversas origens para formato único e plano.|
