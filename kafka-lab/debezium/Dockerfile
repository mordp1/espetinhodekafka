FROM --platform=linux/amd64 quay.io/strimzi/kafka:0.40.0-kafka-3.7.0 AS builder
#FROM --platform=linux/amd64 quay.io/debezium/connect:2.6.1.Final AS builder 
#USER root:root
USER kafka
COPY ./connect-file-3.6.0.jar /opt/kafka/plugins/
COPY ./external_libs /opt/kafka/plugins/external_libs
COPY ./debezium-connector-postgres/ /opt/kafka/plugins/debezium/
#COPY ./apicurio/ /opt/kafka/plugins/apicurio/
USER 1001
