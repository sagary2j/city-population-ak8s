{{/*
Expand the name of the chart.
*/}}
{{- define "city-population.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "city-population.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "city-population.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "city-population.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
App selector labels
*/}}
{{- define "city-population.app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "city-population.name" . }}-api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: api
{{- end -}}

{{/*
Elasticsearch selector labels
*/}}
{{- define "city-population.es.selectorLabels" -}}
app.kubernetes.io/name: {{ include "city-population.name" . }}-elasticsearch
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
{{- end -}}

{{/*
Generic selector labels (kept for reference / backward compat)
*/}}
{{- define "city-population.selectorLabels" -}}
app.kubernetes.io/name: {{ include "city-population.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Target namespace for every resource in this chart. Falls back to
.Release.Namespace (i.e. whatever `-n`/current context provides) when
namespaceOverride is left blank.
*/}}
{{- define "city-population.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{/*
Elasticsearch host URL consumed by the application.
*/}}
{{- define "city-population.esHost" -}}
http://{{ include "city-population.fullname" . }}-elasticsearch:{{ .Values.elasticsearch.service.port }}
{{- end -}}
