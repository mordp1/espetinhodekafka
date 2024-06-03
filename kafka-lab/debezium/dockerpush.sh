#!/bin/bash

TAG=v0.4
NAME=con-debezium

docker buildx build --platform linux/amd64 -t $NAME:$TAG .

docker tag $NAME:$TAG 127.0.0.1:5111/$NAME:$TAG

docker push 127.0.0.1:5111/$NAME:$TAG
