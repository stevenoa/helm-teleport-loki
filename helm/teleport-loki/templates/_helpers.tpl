{{/*
Expand the name of the chart.
*/}}
{{- define "teleport-loki.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "teleport-loki.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "teleport-loki.labels" -}}
helm.sh/chart: {{ include "teleport-loki.chart" . }}
{{ include "teleport-loki.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "teleport-loki.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport-loki.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teleport-loki.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Event-handler specific labels
*/}}
{{- define "teleport-loki.eventHandler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teleport-loki.name" . }}-event-handler
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Fluentd specific labels
*/}}
{{- define "teleport-loki.fluentd.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teleport-loki.name" . }}-fluentd
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
