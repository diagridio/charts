{{/*
Selector labels, matching the StatefulSet's matchLabels.
*/}}
{{- define "piko.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.piko.pikoName }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
