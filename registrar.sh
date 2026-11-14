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
#   registrar.sh --interativo                             assistente: pergunta e valida; sem argumentos
#                                                         num terminal, é o que acontece
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
#   --interativo             assistente para instalar (argumentos já passados pulam as perguntas)
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

uso() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
erro() { printf 'registrar.sh: %s\n' "$*" >&2; exit "${2:-2}"; }
passo() { printf '==> %s\n' "$*"; }

vps=""; chave=""; repo=""; org=""; nome=""; nome_github=""; rotulos=""
modo="instalar"; sem_docker=0; mostrar=0; interativo=0
n_args=$#
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
    --interativo) interativo=1; shift ;;
    -h | --help) uso; exit 0 ;;
    *) erro "opção desconhecida: $1 (veja --help)" ;;
  esac
done

# ---------- assistente interativo ----------
# Pergunta e valida, uma coisa por vez, e depois chama este mesmo script com os argumentos montados
# (--so-checar, instalar, --status). Não grava nada em disco e nunca pergunta o token: ele só é
# gerado, pelo gh, na chamada de instalação, depois da confirmação.
aviso() { printf '  ! %s\n' "$*" >&2; }
fim_da_entrada() { printf '\n'; erro "entrada encerrada; nada foi instalado." 1; }

pergunta() { # <variável> <texto> [padrão]
  local destino="$1" texto="$2" padrao="${3:-}" resposta
  if [ -n "$padrao" ]; then printf '%s [%s]: ' "$texto" "$padrao"; else printf '%s: ' "$texto"; fi
  IFS= read -r resposta || fim_da_entrada
  [ -n "$resposta" ] || resposta="$padrao"
  printf -v "$destino" '%s' "$resposta"
}

sim_nao() { # <texto> <padrão: s|n>; devolve 0 para sim
  local resposta dica="[s/N]" padrao="$2"
  [ "$padrao" != s ] || dica="[S/n]"
  while :; do
    printf '%s %s: ' "$1" "$dica"
    IFS= read -r resposta || fim_da_entrada
    [ -n "$resposta" ] || resposta="$padrao"
    case "${resposta,,}" in
      s | sim | y | yes) return 0 ;;
      n | nao | não | no) return 1 ;;
    esac
    printf 'Responda s ou n.\n'
  done
}

valida_vps() { # <usuário@host[:porta]>
  if ! [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?$ ]]; then
    aviso "VPS inválida: use usuário@host ou usuário@host:porta."; return 1
  fi
  if [[ "$1" == *:* ]] && { [ "${1##*:}" -lt 1 ] || [ "${1##*:}" -gt 65535 ]; }; then
    aviso "porta fora do intervalo 1-65535."; return 1
  fi
}

valida_chave() { # <caminho de um arquivo legível>
  if [ -f "$1" ] && [ -r "$1" ]; then return 0; fi
  aviso "não achei (ou não consigo ler) a chave: $1"; return 1
}

valida_nome() {
  [[ "$1" =~ ^[a-z0-9-]+$ ]] || { aviso "o nome só aceita letras minúsculas, números e hífen."; return 1; }
}

ssh_assistente() { # <comando remoto…>; sem terminal, sem senha (BatchMode)
  local -a a=()
  [ -z "$chave" ] || a+=(-i "$chave")
  [ -z "$vps_porta" ] || a+=(-p "$vps_porta")
  "$ssh_cmd" "${a[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$vps_host" "$@" < /dev/null
}

define_destino() { # separa host e porta de $vps
  vps_host="$vps"; vps_porta=""
  if [[ "$vps" == *:* ]]; then vps_host="${vps%%:*}"; vps_porta="${vps##*:}"; fi
}

valida_alvo() { # usa $repo ou $org; confere se o gh é administrador
  local adm papel
  if [ -n "$repo" ]; then
    if ! adm="$("$gh_cmd" api "repos/$repo" --jq .permissions.admin 2> /dev/null < /dev/null)"; then
      aviso "não consegui ler $repo (o nome está certo? o gh enxerga esse repositório?)"; return 1
    fi
    [ "$adm" = true ] || { aviso "o gh não é administrador de $repo: só administradores geram o token de registro."; return 1; }
  else
    if ! papel="$("$gh_cmd" api "user/memberships/orgs/$org" --jq .role 2> /dev/null < /dev/null)"; then
      aviso "não consegui ler a sua participação em $org (o nome está certo? você faz parte dela?)"; return 1
    fi
    [ "$papel" = admin ] || { aviso "o gh não é administrador da organização $org: só administradores geram o token de registro."; return 1; }
  fi
}

assistente() {
  local mem="" cpu="" rot="" self="${BASH_SOURCE[0]}" alvo_texto padrao_nome resposta v
  local -a base=() alvo=()

  printf 'Assistente do registrar.sh: instala um runner self-hosted numa VPS.\n'
  printf 'Responda Enter para aceitar o valor entre colchetes. Ctrl-C cancela; nada é instalado antes da confirmação.\n\n'

  "$gh_cmd" auth status > /dev/null 2>&1 < /dev/null \
    || erro "o gh não está autenticado: rode 'gh auth login' (como administrador do repositório ou da organização)." 1

  # Argumentos já passados valem, mas passam pelas mesmas validações.
  if [ -n "$vps" ]; then valida_vps "$vps" || exit 2; fi
  if [ -n "$chave" ]; then valida_chave "$chave" || exit 2; fi
  if [ -n "$repo" ] && [ -n "$org" ]; then erro "use --repo ou --org, não os dois"; fi
  if [ -n "$repo" ] && ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then erro "--repo espera <dono>/<repo>: $repo"; fi
  if [ -n "$org" ] && ! [[ "$org" =~ ^[A-Za-z0-9._-]+$ ]]; then erro "--org inválida: $org"; fi
  if [ -n "$nome" ]; then valida_nome "$nome" || exit 2; fi
  for v in "${extras[@]}"; do
    [[ "$v" =~ ^[A-Z][A-Z0-9_]*=.*$ ]] || erro "--var espera CHAVE=valor, com a chave em maiúsculas: $v"
    [[ "$v" != RUNNER_TOKEN=* ]] || erro "não passe RUNNER_TOKEN por --var: o script gera o token"
  done

  # 1. VPS e chave, com teste de conexão de verdade.
  while :; do
    if [ -z "$vps" ]; then
      while :; do
        pergunta vps "VPS (usuário@host ou usuário@host:porta)"
        if valida_vps "$vps"; then break; fi
        vps=""
      done
      while :; do
        pergunta chave "Chave privada do SSH (Enter para a padrão ou o ssh-agent)"
        case "$chave" in \~/*) chave="$HOME/${chave#\~/}" ;; esac
        if [ -z "$chave" ] || valida_chave "$chave"; then break; fi
        chave=""
      done
    fi
    define_destino
    printf 'Testando a conexão com %s...\n' "$vps"
    if ssh_assistente true > /dev/null 2>&1; then printf '  ok\n'; break; fi
    aviso "não consegui conectar em $vps. Confira host, porta e chave. O assistente usa BatchMode: chave com senha precisa estar no ssh-agent."
    vps=""; chave=""
  done

  # 2. Repositório ou organização.
  while [ -z "$repo" ] && [ -z "$org" ] || ! valida_alvo; do
    repo=""; org=""
    pergunta alvo_texto "Repositório (<dono>/<repo>) ou organização (<org>)"
    if [[ "$alvo_texto" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then repo="$alvo_texto"
    elif [[ "$alvo_texto" =~ ^[A-Za-z0-9._-]+$ ]]; then org="$alvo_texto"
    else aviso "use <dono>/<repo> para um repositório ou só <org> para uma organização."; fi
  done
  if [ -n "$repo" ]; then alvo=(--repo "$repo"); alvo_texto="repositório $repo"
  else alvo=(--org "$org"); alvo_texto="organização $org"; fi

  # 3. Nome da instância (sugestão derivada do alvo); avisa se já existe na VPS.
  padrao_nome="${repo#*/}"; [ -n "$repo" ] || padrao_nome="$org"
  padrao_nome="${padrao_nome,,}"; padrao_nome="${padrao_nome//[^a-z0-9-]/-}"
  while :; do
    if [ -z "$nome" ]; then
      pergunta nome "Nome da instância (vira o usuário runner-<nome> na VPS)" "$padrao_nome"
      if ! valida_nome "$nome"; then nome=""; continue; fi
    fi
    if ssh_assistente "test -e /etc/runner-vps/$nome.conf" > /dev/null 2>&1; then
      if sim_nao "Já existe uma instância \"$nome\" nessa VPS. Reaplicar por cima (é idempotente)?" n; then break; fi
      nome=""; continue
    fi
    break
  done

  # 4. Opções avançadas (opcionais).
  if sim_nao "Ajustar opções avançadas (limites, rótulos, Docker)?" n; then
    while :; do
      pergunta mem "Memória máxima do runner em MB (vazio = calculada pelo diagnóstico)"
      if [ -z "$mem" ] || [[ "$mem" =~ ^[0-9]+$ ]]; then break; fi
      aviso "use só números (MB)."
    done
    while :; do
      pergunta cpu "Cota de CPU em % de um núcleo, ex.: 200 (vazio = calculada)"
      if [ -z "$cpu" ] || [[ "$cpu" =~ ^[0-9]+%?$ ]]; then break; fi
      aviso "use só números, ex.: 200."
    done
    while :; do
      pergunta rot "Rótulos do runner separados por vírgula (vazio = o nome)"
      if [ -z "$rot" ] || [[ "$rot" =~ ^[A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*$ ]]; then break; fi
      aviso "use rótulos simples separados por vírgula, sem espaços."
    done
    [ -z "$mem" ] || extras+=("MEMORY_MAX_MB=$mem")
    [ -z "$cpu" ] || extras+=("CPU_QUOTA=${cpu%\%}")
    [ -z "$rot" ] || rotulos="$rot"
    sim_nao "Instalar o Docker rootless do runner?" s || sem_docker=1
  fi

  # Argumentos comuns às três chamadas (nunca contêm o token).
  base=(--vps "$vps" --nome "$nome")
  [ -z "$chave" ] || base+=(--chave "$chave")
  [ -z "$rotulos" ] || base+=(--rotulos "$rotulos")
  [ -z "$nome_github" ] || base+=(--nome-github "$nome_github")
  [ "$sem_docker" -eq 0 ] || base+=(--sem-docker)
  for v in "${extras[@]}"; do base+=(--var "$v"); done

  # 5. Diagnóstico: se não couber, para antes de gerar qualquer token.
  printf '\nDiagnóstico da VPS (não cria nada):\n'
  if ! bash "$self" "${base[@]}" --so-checar < /dev/null; then
    erro "o diagnóstico disse que não cabe (ou falhou); nada foi instalado." 1
  fi

  # 6. Resumo e confirmação.
  printf '\nResumo:\n  VPS:        %s\n  Alvo:       %s\n  Instância:  %s (usuário runner-%s na VPS)\n' "$vps" "$alvo_texto" "$nome" "$nome"
  printf '  Docker rootless: %s\n' "$([ "$sem_docker" -eq 0 ] && echo sim || echo não)"
  if ! sim_nao "Instalar agora?" n; then
    printf 'Nada foi instalado.\n'; exit 0
  fi

  # 7. Instala (o token é gerado aqui, pelo gh) e mostra o estado.
  if ! bash "$self" "${base[@]}" "${alvo[@]}" < /dev/null; then
    erro "a instalação falhou (veja as mensagens acima)." 1
  fi
  printf '\nEstado da instância:\n'
  bash "$self" "${base[@]}" --status < /dev/null || aviso "não consegui ler o estado agora; rode --status depois."
  printf '\nPara repetir sem o assistente:\n  ./registrar.sh'
  for resposta in "${base[@]}" "${alvo[@]}"; do printf ' %q' "$resposta"; done
  printf '\n'
}

if [ "$n_args" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then interativo=1; fi
if [ "$interativo" -eq 1 ]; then
  [ "$modo" = instalar ] || erro "--interativo só serve para instalar (sem --status, --so-checar, --remover ou --sem-token)"
  [ "$mostrar" -eq 0 ] || erro "--interativo não combina com --mostrar"
  assistente
  exit 0
fi

[ -n "$vps" ] || erro "falta --vps root@<vps>[:porta] (ou use --interativo)"
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
