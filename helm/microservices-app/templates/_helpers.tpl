{{/*
Expand the chart name.
*/}}
{{- define "microservices-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a release-scoped base name.
*/}}
{{- define "microservices-app.fullname" -}}
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
Chart name and version used by the standard Helm label.
*/}}
{{- define "microservices-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Generate a stable resource name for one service.
Input: dict with root, key and service.
*/}}
{{- define "microservices-app.serviceFullname" -}}
{{- printf "%s-%s" (include "microservices-app.fullname" .root) .service.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Labels shared by all resources for one service.
*/}}
{{- define "microservices-app.serviceLabels" -}}
helm.sh/chart: {{ include "microservices-app.chart" .root }}
{{ include "microservices-app.selectorLabels" . }}
app.kubernetes.io/component: {{ .service.name | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/version: {{ required (printf "services.%s.env.APP_VERSION is required" .key) (get .service.env "APP_VERSION") | quote }}
{{- end }}

{{/*
Immutable selector labels. Keep this set small so values unrelated to identity
can change without replacing Deployments.
*/}}
{{- define "microservices-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .service.name | quote }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
{{- end }}

{{/*
Render ConfigMap data consistently for both the ConfigMap and its pod checksum.
*/}}
{{- define "microservices-app.configData" -}}
{{- range $name, $value := .service.env }}
{{ $name }}: {{ $value | toString | quote }}
{{- end }}
{{- end }}

{{/*
Build the image reference. A registry and owner must be supplied together;
otherwise the explicit per-service repository is used.
*/}}
{{- define "microservices-app.image" -}}
{{- $registry := .root.Values.global.imageRegistry | default "" -}}
{{- $owner := .root.Values.global.imageOwner | default "" -}}
{{- if ne (empty $registry) (empty $owner) -}}
{{- fail "global.imageRegistry and global.imageOwner must be set together" -}}
{{- end -}}
{{- $repository := required (printf "services.%s.image.repository is required" .key) .service.image.repository -}}
{{- if and $registry $owner -}}
{{- $repository = printf "%s/%s/%s" (trimSuffix "/" $registry) (trimAll "/" $owner) .service.name -}}
{{- end -}}
{{- printf "%s:%s" $repository (required (printf "services.%s.image.tag is required" .key) .service.image.tag) -}}
{{- end }}
