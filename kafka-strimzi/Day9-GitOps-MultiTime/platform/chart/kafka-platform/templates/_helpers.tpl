{{/* Replication factor never exceeds the number of brokers; min.isr = RF-1 (>=1). */}}
{{- define "kafka-platform.rf" -}}
{{- min 3 (int .Values.kafka.replicas) -}}
{{- end -}}
{{- define "kafka-platform.isr" -}}
{{- max 1 (sub (int (include "kafka-platform.rf" .)) 1) -}}
{{- end -}}
{{- define "kafka-platform.labels" -}}
app.kubernetes.io/part-of: kafka-platform
app.kubernetes.io/managed-by: argocd
kafka.platform/region: {{ .Values.region | quote }}
kafka.platform/env: {{ .Values.env | quote }}
{{- end -}}
