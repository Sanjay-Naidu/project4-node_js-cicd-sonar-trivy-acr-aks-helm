{{/*
Chart name, overridable.
*/}}
{{- define "orders-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated to 63 chars because that is the limit for
a Kubernetes resource name, and the Service name becomes a DNS label.
*/}}
{{- define "orders-api.fullname" -}}
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

{{- define "orders-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels.

These land in Deployment.spec.selector, which is IMMUTABLE after creation.
Only the two genuinely identifying labels go here - putting version or chart
labels in a selector makes every chart bump require deleting the Deployment.
*/}}
{{- define "orders-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "orders-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Full label set for metadata (safe to change between releases).
*/}}
{{- define "orders-api.labels" -}}
helm.sh/chart: {{ include "orders-api.chart" . }}
{{ include "orders-api.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: orders-platform
{{- end }}

{{- define "orders-api.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "orders-api.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Fully-qualified image reference.

Deliberately does NOT fall back to .Chart.AppVersion. A fallback looks helpful
but is the worse failure: an unset tag would render a plausible-looking
"1.0.0" that almost certainly is not in the registry, and the operator finds
out via ImagePullBackOff instead of a message telling them what is wrong.
Every deployment must name an explicit, immutable tag - CD passes the git SHA.

"latest" is rejected for the same reason it is never used: it is mutable, so
two pods in one ReplicaSet can end up running different code and a rollback
means nothing.
*/}}
{{- define "orders-api.image" -}}
{{- $tag := .Values.image.tag | toString -}}
{{- if eq $tag "" -}}
{{- fail "image.tag is required. Pass the immutable build tag, e.g. --set image.tag=$(git rev-parse --short=7 HEAD)." -}}
{{- end -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be an immutable tag (the git SHA). Refusing to deploy 'latest'." -}}
{{- end -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end }}
