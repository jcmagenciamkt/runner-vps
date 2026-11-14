#!/usr/bin/env bash
# registrar.sh — instala, confere, mostra ou remove um runner numa VPS, a partir da sua máquina.
#
# Gera o token de registro pela API do GitHub (gh api), monta as variáveis do instalar.sh e envia
# tudo pelo SSH. O token vai pelo fluxo de entrada do SSH, junto com o script: nunca passa pela
# linha de comando (ps), pelo histórico do shell nem por arquivo.
#
# Uso:
#   registrar.sh --vps root@<vps>[:porta] (--repo <dono>/<repo> | --org <org>) --nome <nome> [opções]
#   registrar.sh --vps … --nome <nome> --so-checar        só o diagnóstico (sem token)
#   registrar.sh --vps … --nome <nome> --status           estado da instância (sem token)
#   registrar.sh --vps … (--repo|--org) --nome <nome> --remover   desfaz a instância (token de remoção)
#   registrar.sh --vps … --nome <nome> --sem-token        reinstala/atualiza sem registrar de novo
#
# Opções:
#   --chave <arquivo>        chave privada do SSH (-i)
#   --rotulos a,b            rótulos do runner (padrão: o nome)
#   --nome-github <nome>     nome do runner no GitHub, se diferente de --nome
#   --sem-docker             DOCKER_ROOTLESS=0
#   --var CHAVE=valor        qualquer variável do instalar.sh (repetível): RESERVA_MB, MEM_MIN_MB,
#                            DISCO_MIN_GB, MEMORY_MAX_MB, CPU_QUOTA, HOSTS_EXTRAS, PACOTES_EXTRAS,
#                            EXTRAS_SH, EXTRAS_SHA256, ENV_EXTRAS, RUNNER_VERSAO, RUNNER_SHA256
#   --mostrar                imprime o que seria enviado (token redigido) e não conecta
#   -h, --help
#
# Pré-requisitos: gh autenticado (gh auth status) com acesso de administrador ao repositório
# (ou à organização), ssh, e o instalar.sh ao lado deste script.
#
# Variáveis só de teste (padrão: o comando real): GH_CMD, SSH_CMD, INSTALAR_SH.
set -euo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_cmd="${GH_CMD:-gh}"
ssh_cmd="${SSH_CMD:-ssh}"
instalar="${INSTALAR_SH:-$aqui/instalar.sh}"

uso() { sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
erro() { printf 'registrar.sh: %s\n' "$*" >&2; exit "${2:-2}"; }
passo() { printf '==> %s\n' "$*"; }

vps=""; chave=""; repo=""; org=""; nome=""; nome_github=""; rotulos=""
modo="instalar"; sem_docker=0; mostrar=0
declare -a extras=()

while [ $# -gt 0 ]; do
  case "$1" in
    --vps) vps="${2:-}"; shift 2 ;;
    --chave) chave="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --org) org="${2:-}"; shift 2 ;;
    --nome) nome="${2:-}"; shift 2 ;;
    --nome-github) nome_github="${2:-}"; shift 2 ;;
    --rotulos) rotulos="${2:-}"; shift 2 ;;
    --sem-docker) sem_docker=1; shift ;;
    --var) extras+=("${2:-}"); shift 2 ;;
    --so-checar) modo="so-checar"; shift ;;
    --status) modo="status"; shift ;;
    --remover) modo="remover"; shift ;;
    --sem-token) modo="sem-token"; shift ;;
    --mostrar) mostrar=1; shift ;;
    -h | --help) uso; exit 0 ;;
    *) erro "opção desconhecida: $1 (veja --help)" ;;
  esac
done

[ -n "$vps" ] || erro "falta --vps root@<vps>[:porta]"
[ -n "$nome" ] || erro "falta --nome <nome>"
[[ "$nome" =~ ^[a-z0-9-]+$ ]] || erro "--nome só aceita [a-z0-9-]: $nome"
[ -r "$instalar" ] || erro "não achei o instalar.sh em $instalar" 1
for v in "${extras[@]}"; do
  [[ "$v" =~ ^[A-Z][A-Z0-9_]*=.*$ ]] || erro "--var espera CHAVE=valor, com a chave em maiúsculas: $v"
  [[ "$v" != RUNNER_TOKEN=* ]] || erro "não passe RUNNER_TOKEN por --var: o script gera o token"
done

# Destino: user@host[:porta]
host="$vps"; porta=""
if [[ "$vps" == *:* ]]; then
  host="${vps%%:*}"; porta="${vps##*:}"
  [[ "$porta" =~ ^[0-9]+$ ]] || erro "porta inválida em --vps: $porta"
fi

# Alvo da API e URL do runner.
alvo_api=""; runner_url=""
if [ -n "$repo" ] && [ -n "$org" ]; then erro "use --repo ou --org, não os dois"; fi
if [ -n "$repo" ]; then
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || erro "--repo espera <dono>/<repo>: $repo"
  alvo_api="repos/$repo"; runner_url="https://github.com/$repo"
elif [ -n "$org" ]; then
  [[ "$org" =~ ^[A-Za-z0-9._-]+$ ]] || erro "--org inválida: $org"
  alvo_api="orgs/$org"; runner_url="https://github.com/$org"
fi

precisa_token=0
case "$modo" in
  instalar) [ -n "$alvo_api" ] || erro "instalar precisa de --repo ou --org"; precisa_token=1 ;;
  remover) [ -n "$alvo_api" ] || erro "--remover precisa de --repo ou --org (token de remoção)"; precisa_token=1 ;;
  so-checar | status | sem-token) ;;
esac

# Token pela API, só quando necessário. Nunca é impresso.
token=""
if [ "$precisa_token" -eq 1 ] && [ "$mostrar" -eq 0 ]; then
  tipo="registration-token"; [ "$modo" = "remover" ] && tipo="remove-token"
  passo "Gerando o token de $tipo pela API do GitHub ($alvo_api)"
  token="$("$gh_cmd" api -X POST "$alvo_api/actions/runners/$tipo" --jq .token)" \
    || erro "não consegui gerar o token (gh auth status? permissão de administrador?)" 1
  [ -n "$token" ] || erro "a API devolveu um token vazio" 1
fi

# Bloco de variáveis que vai na frente do script, pelo stdin do ssh.
montar_env() {
  local redigir="${1:-0}"
  printf 'export RUNNER_NOME=%q\n' "$nome"
  [ -z "$runner_url" ] || printf 'export RUNNER_URL=%q\n' "$runner_url"
  [ -z "$nome_github" ] || printf 'export RUNNER_NOME_GITHUB=%q\n' "$nome_github"
  [ -z "$rotulos" ] || printf 'export RUNNER_ROTULOS=%q\n' "$rotulos"
  [ "$sem_docker" -eq 0 ] || printf 'export DOCKER_ROOTLESS=0\n'
  local v
  for v in "${extras[@]}"; do printf 'export %s=%q\n' "${v%%=*}" "${v#*=}"; done
  if [ "$precisa_token" -eq 1 ]; then
    if [ "$redigir" -eq 1 ]; then printf 'export RUNNER_TOKEN=<redigido>\n'
    else printf 'export RUNNER_TOKEN=%q\n' "$token"; fi
  fi
}

argumento=""
case "$modo" in
  so-checar) argumento="--so-checar" ;;
  status) argumento="--status" ;;
  remover) argumento="--remover" ;;
esac

declare -a ssh_args=()
[ -z "$chave" ] || ssh_args+=(-i "$chave")
[ -z "$porta" ] || ssh_args+=(-p "$porta")
ssh_args+=(-o BatchMode=yes "$host" "bash -s -- $argumento")

if [ "$mostrar" -eq 1 ]; then
  passo "Comando: $ssh_cmd ${ssh_args[*]}"
  passo "Entrada (depois destas linhas vai o instalar.sh):"
  montar_env 1
  exit 0
fi

passo "Enviando o instalar.sh para $host ($modo)"
# O token entra só aqui, pelo stdin do ssh: não há linha de comando nem arquivo com ele.
{ montar_env 0; cat "$instalar"; } | "$ssh_cmd" "${ssh_args[@]}"
