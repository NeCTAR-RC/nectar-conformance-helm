{{- define "ncw.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ncw.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "ncw.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "ncw.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ncw.labels" -}}
helm.sh/chart: {{ include "ncw.chart" . }}
{{ include "ncw.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
nectar-conformance/tier: {{ .Values.tier | quote }}
{{- end -}}

{{- define "ncw.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ncw.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ncw.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{/* The checks directory the tool reads: git-sync's stable symlink under the mount point. */}}
{{- define "ncw.checksDir" -}}
{{- printf "%s/current" .Values.checks.mountPath -}}
{{- end -}}

{{/*
A git-sync container that clones the checks repo into the shared "checks" volume.
Call with a dict: (dict "ctx" $ "name" "git-sync-init" "oneTime" true).
oneTime=true is an init container (clone once, exit); false is a sidecar (periodic pull).
*/}}
{{- define "ncw.gitsync" -}}
{{- $ctx := .ctx -}}
{{- $git := $ctx.Values.checks.git -}}
- name: {{ .name }}
  image: {{ $git.image }}
  imagePullPolicy: {{ $ctx.Values.image.pullPolicy }}
  securityContext:
    {{- toYaml $ctx.Values.securityContext | nindent 4 }}
  args:
    - --repo={{ required "checks.git.repo is required when checks.git.enabled" $git.repo }}
    - --ref={{ $git.ref | default "master" }}
    - --root={{ $ctx.Values.checks.mountPath }}
    - --link=current
    - --depth={{ $git.depth | default 1 }}
    - --max-failures={{ $git.maxFailures | default 3 }}
    {{- if .oneTime }}
    - --one-time
    {{- else }}
    - --period={{ $git.period | default "1m" }}
    {{- end }}
    {{- if $git.secretName }}
    - --ssh
    - --ssh-key-file=/etc/git-secret/ssh
    - --ssh-known-hosts=false
    {{- end }}
  volumeMounts:
    - name: checks
      mountPath: {{ $ctx.Values.checks.mountPath }}
    {{- if $git.secretName }}
    - name: git-secret
      mountPath: /etc/git-secret
      readOnly: true
    {{- end }}
  resources:
    {{- toYaml $git.resources | nindent 4 }}
{{- end -}}

{{/*
The "checks" volume plus the optional git-secret volume, for a pod that git-syncs.
Call with the root context ($). Renders nothing when checks.git is disabled.
*/}}
{{- define "ncw.checksVolumes" -}}
{{- if .Values.checks.git.enabled }}
- name: checks
  emptyDir: {}
{{- if .Values.checks.git.secretName }}
- name: git-secret
  secret:
    secretName: {{ .Values.checks.git.secretName }}
    defaultMode: 0400
{{- end }}
{{- end }}
{{- end -}}
