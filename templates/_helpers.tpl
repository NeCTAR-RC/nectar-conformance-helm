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

{{/* The ServiceAccount both pods run as: the release name (the Vault auth role binds to it). */}}
{{- define "ncw.serviceAccountName" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
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
Truthy (non-empty string) when git-sync authenticates over SSH: either a Vault-injected
deploy key or a mounted Kubernetes Secret. Call with the root context ($).
*/}}
{{- define "ncw.gitSshEnabled" -}}
{{- $git := .Values.checks.git -}}
{{- if and $git.enabled (or (and $git.vault $git.vault.enabled) $git.secretName) -}}true{{- end -}}
{{- end -}}

{{/*
A git-sync container that clones the checks repo into the shared "checks" volume.
Call with a dict: (dict "ctx" $ "name" "git-sync-init" "oneTime" true).
oneTime=true is an init container (clone once, exit); false is a sidecar (periodic pull).
*/}}
{{- define "ncw.gitsync" -}}
{{- $ctx := .ctx -}}
{{- $git := $ctx.Values.checks.git -}}
{{- $vaultEnabled := and $git.vault $git.vault.enabled -}}
{{- $ssh := or $vaultEnabled $git.secretName -}}
- name: {{ .name }}
  image: {{ $git.image }}
  imagePullPolicy: {{ $ctx.Values.image.pullPolicy }}
  securityContext:
    {{- toYaml $ctx.Values.securityContext | nindent 4 }}
  {{- if $ssh }}
  env:
    # SSH and git resolve $HOME; point it at the writable tmp volume (the read-only root has none).
    - name: HOME
      value: /tmp
  {{- end }}
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
    {{- if $ssh }}
    - --ssh-key-file={{ if $vaultEnabled }}{{ $git.sshKeyFile | default "/vault/secrets/ssh" }}{{ else }}/etc/git-secret/ssh{{ end }}
    - --ssh-known-hosts=false
    {{- end }}
  volumeMounts:
    - name: checks
      mountPath: {{ $ctx.Values.checks.mountPath }}
    # git-sync writes temporary git data to /tmp, which the read-only root filesystem
    # (securityContext.readOnlyRootFilesystem) would otherwise forbid.
    - name: git-tmp
      mountPath: /tmp
    {{- if $ssh }}
    # SSH resolves the current UID via getpwuid(); the git-sync image has no /etc/passwd entry
    # for securityContext.runAsUser, so ssh aborts with "No user exists for uid <uid>". Mount an
    # entry for it. A mounted file works under readOnlyRootFilesystem; git-sync's --add-user
    # would instead need a writable /etc/passwd, which the read-only root forbids.
    - name: git-sync-passwd
      mountPath: /etc/passwd
      subPath: passwd
      readOnly: true
    {{- end }}
    {{- if and $git.secretName (not $vaultEnabled) }}
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
- name: git-tmp
  emptyDir: {}
{{- if include "ncw.gitSshEnabled" . }}
- name: git-sync-passwd
  configMap:
    name: {{ include "ncw.fullname" . }}-git-sync-passwd
{{- end }}
{{- if and .Values.checks.git.secretName (not (and .Values.checks.git.vault .Values.checks.git.vault.enabled)) }}
- name: git-secret
  secret:
    secretName: {{ .Values.checks.git.secretName }}
    defaultMode: 0400
{{- end }}
{{- end }}
{{- end -}}

{{/*
Vault Agent Injector annotations for the pods that git-sync the checks repo, so the SSH
deploy key is injected at checks.git.sshKeyFile. Call with the root context ($). Renders
nothing unless checks.git.vault.enabled. agent-run-as-same-user makes the agent run as the
workload UID (set in securityContext.runAsUser) so the 0400 key is readable by git-sync;
agent-pre-populate-only injects only an init container (the key is static);
agent-init-first runs that init container before git-sync-init, so the key is rendered
before git-sync tries to read it (otherwise git-sync-init runs first and fails).
*/}}
{{- define "ncw.vaultAnnotations" -}}
{{- $git := .Values.checks.git -}}
{{- if and $git.enabled $git.vault $git.vault.enabled }}
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/agent-pre-populate-only: "true"
vault.hashicorp.com/agent-init-first: "true"
vault.hashicorp.com/agent-run-as-same-user: "true"
vault.hashicorp.com/role: {{ required "checks.git.vault.role is required when checks.git.vault.enabled" $git.vault.role | quote }}
vault.hashicorp.com/agent-inject-secret-ssh: {{ $git.vault.secretPath | quote }}
vault.hashicorp.com/agent-inject-perms-ssh: "0400"
vault.hashicorp.com/agent-inject-template-ssh: {{ include "ncw.vaultSshTemplate" . | quote }}
{{- with $git.vault.annotations }}
{{ toYaml . }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The Vault Agent template that renders the raw SSH private key. Defaults to a KV v2 read of
secretKey at secretPath; override with checks.git.vault.template. The literal {{ }} below are
emitted verbatim for the agent (consul-template), not evaluated by Helm.
*/}}
{{- define "ncw.vaultSshTemplate" -}}
{{- $v := .Values.checks.git.vault -}}
{{- if $v.template -}}
{{ $v.template }}
{{- else -}}
{{ printf "{{ with secret %q }}{{ .Data.data.%s }}{{ end }}" $v.secretPath $v.secretKey }}
{{- end -}}
{{- end -}}
