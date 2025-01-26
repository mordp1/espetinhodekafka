# /bin/bash
#KUBECONTEXT=$1
BROKER=$1
REPLICATION=$2


# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
# Download kafka binaries
wget -c https://dlcdn.apache.org/kafka/3.7.1/kafka_2.13-3.7.1.tgz -O - | tar -xz

# Download kafkactl
wget -c https://github.com/deviceinsight/kafkactl/releases/download/v4.0.0/kafkactl_4.0.0_linux_amd64.tar.gz -O - | tar -xz

chmod +x kafkactl

# Create kafkactl.yaml
cat <<EOF > kafkactl.yaml
contexts:
  default:
    brokers:
      - $BROKER
#    kubernetes:
#      enabled: true
#      binary: kubectl #optional
#      kubeContext: $KUBECONTEXT
#      namespace: kafka-system
EOF
log_file="log_$(date +'%Y-%m-%d_%H-%M-%S').txt"
mv list.txt list.txt-bkp

# List topics and store in a file
echo "Genearte List of all topics, you can use this list to do the rollback."
echo "Current date and time: $(date +'%Y-%m-%d %H:%M:%S')" >> $log_file
./kafkactl --config-file=kafkactl.yaml list topics | grep -v '^_' > list.txt

while read -r line; do
  topic=$(echo $line | awk '{print $1}')
  size=$(kafka-log-dirs.sh --bootstrap-server $BROKER --describe --topic-list $topic | grep -oP '(?<=size":)\d+' | awk '{ sum += $1 } END { printf "%.2f\n", sum / (1024^2) }')
  echo "Altering topic $topic with size $size MB..."
  ./kafkactl --config-file=kafkactl.yaml alter topic $topic --replication-factor $REPLICATION
  echo "Altered topic $topic. Waiting for 10 seconds before next operation..."
  if awk -v size="$size" 'BEGIN {if (size > 5000) exit 1; else exit 0}'; then  # Replace 1000 with the size you want to check for
    echo "The size of the topic is small. Proceeding..."
    sleep 10
  else
    echo "The size of the topic is large ( > 5GB). Waiting for more time..."
    sleep 60
  fi
done < list.txt

cat list.txt >> $log_file
echo "--------------------------------------" >> $log_file
echo "----------------END-------------------" >> $log_file
echo "--------------------------------------" >> $log_file
echo "Current date and time: $(date +'%Y-%m-%d %H:%M:%S')" >> $log_file