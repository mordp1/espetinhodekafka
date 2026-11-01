{{/*
Physical topic name = <topicPrefix><owner>.<topic>
  - "events"            (no dot)  -> own topic        -> <prefix><app>.events
  - "payments.refunds"  (a dot)   -> another team's   -> <prefix>payments.refunds
The team name is ALWAYS part of the physical name, so a team can never declare a topic in someone
else's namespace: ownership is structural, not a convention.
*/}}
{{- define "kafka-tenant.topicName" -}}
{{- if contains "." .ref -}}
{{- printf "%s%s" .ctx.Values.topicPrefix .ref -}}
{{- else -}}
{{- printf "%s%s.%s" .ctx.Values.topicPrefix .ctx.Values.app .ref -}}
{{- end -}}
{{- end -}}

{{- define "kafka-tenant.labels" -}}
app.kubernetes.io/part-of: kafka-tenants
tenant.kafka/team: {{ .Values.app | quote }}
tenant.kafka/env: {{ .Values.env | quote }}
tenant.kafka/cluster: {{ .Values.cluster | quote }}
{{- end -}}
