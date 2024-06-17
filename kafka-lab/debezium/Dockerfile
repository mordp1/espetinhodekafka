FROM --platform=linux/amd64 quay.io/strimzi/kafka:0.41.0-kafka-3.7.0 AS builder
USER root:root
COPY ./plugins /opt/kafka/plugins/
COPY ./plugins/apicurio/*.jar /opt/kafka/libs/
USER 1001