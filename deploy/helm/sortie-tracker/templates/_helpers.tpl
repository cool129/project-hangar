{{- define "sortie-tracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "sortie-tracker.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- include "sortie-tracker.name" . }}
{{- end }}
{{- end }}

{{- define "sortie-tracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sortie-tracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "sortie-tracker.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ include "sortie-tracker.selectorLabels" . }}
app.kubernetes.io/version: {{ include "sortie-tracker.imageTag" . | quote }}
app.kubernetes.io/part-of: project-hangar
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "sortie-tracker.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{/* repository@digest when a digest is given (immutable), else repository:tag. */}}
{{- define "sortie-tracker.image" -}}
{{- $repo := required "image.repository is required" .Values.image.repository }}
{{- if .Values.image.digest }}
{{- printf "%s@%s" $repo .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" $repo (include "sortie-tracker.imageTag" .) }}
{{- end }}
{{- end }}

{{/* Env, volume mounts and security context shared by the app and migrate containers. */}}
{{- define "sortie-tracker.containerCommon" -}}
image: {{ include "sortie-tracker.image" . }}
imagePullPolicy: {{ .Values.image.pullPolicy }}
securityContext:
  {{- toYaml .Values.securityContext | nindent 2 }}
env:
  - name: APP_ENV
    value: {{ .Values.app.environment | quote }}
  - name: LOG_LEVEL
    value: {{ .Values.app.logLevel | quote }}
  - name: DB_SSLMODE
    value: {{ .Values.app.dbSslMode | quote }}
  - name: SECRETS_DIR
    value: {{ .Values.secrets.mountPath | quote }}
  - name: GIT_SHA
    value: {{ include "sortie-tracker.imageTag" . | quote }}
volumeMounts:
  - name: secrets
    mountPath: {{ .Values.secrets.mountPath }}
    readOnly: true
  - name: tmp
    mountPath: /tmp
{{- end }}
