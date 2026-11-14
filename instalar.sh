#!/usr/bin/env bash
# instalar.sh — instala um runner self-hosted do GitHub Actions numa VPS Linux, em usuário sem privilégio.
# Roda NA VPS, como root, enviado por `ssh … 'bash -s -- [subcomando]'` (veja registrar.sh e docs/design.md).
# As variáveis vêm do ambiente; o stdin não é lido. RUNNER_TOKEN nunca é impresso nem gravado.
#
# Uso: instalar.sh [--so-checar | --status | --remover]
set -euo pipefail

passo() { printf '==> %s\n' "$*"; }
aviso() { printf 'AVISO: %s\n' "$*" >&2; }
erro() { printf 'ERRO: %s\n' "$*" >&2; }
uso() {
  cat >&2 <<'USO'
Uso: instalar.sh [--so-checar | --status | --remover]
Variáveis: RUNNER_NOME (obrigatória, [a-z0-9-]+); RUNNER_URL (no primeiro instalar);
opcionais: RUNNER_TOKEN, RUNNER_NOME_GITHUB, RUNNER_ROTULOS, DOCKER_ROOTLESS, RESERVA_MB, MEM_MIN_MB,
DISCO_MIN_GB, MEMORY_MAX_MB, CPU_QUOTA, HOSTS_EXTRAS, PACOTES_EXTRAS, EXTRAS_SH, EXTRAS_SHA256, ENV_EXTRAS.
USO
}

# Variáveis que a instância persiste em /etc/runner-vps/<nome>.conf (nunca o token).
CHAVES=(RUNNER_URL RUNNER_NOME_GITHUB RUNNER_ROTULOS DOCKER_ROOTLESS RESERVA_MB MEM_MIN_MB DISCO_MIN_GB
  MEMORY_MAX_MB CPU_QUOTA HOSTS_EXTRAS PACOTES_EXTRAS EXTRAS_SH EXTRAS_SHA256 ENV_EXTRAS)

# ---------- argumentos e identidade ----------
SUB="${1:-}"
if [ "$#" -gt 1 ]; then uso; exit 2; fi
case "$SUB" in
  "" | --so-checar | --status | --remover) ;;
  *) erro "argumento desconhecido: $SUB"; uso; exit 2 ;;
esac

RUNNER_NOME="${RUNNER_NOME:-}"
if [ -z "$RUNNER_NOME" ]; then erro "RUNNER_NOME é obrigatório."; uso; exit 2; fi
if ! [[ "$RUNNER_NOME" =~ ^[a-z0-9-]+$ ]]; then
  erro "RUNNER_NOME inválido: use só letras minúsculas, números e hífen."; exit 2
fi

if [ "${SOU_ROOT:-}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  erro "rode como root."; exit 1
fi

# RAIZ é o prefixo de /etc, /opt e /run (vazio na VPS real; um diretório temporário nos testes).
RAIZ="${RAIZ:-}"
CONF="$RAIZ/etc/runner-vps/$RUNNER_NOME.conf"

# ---------- configuração: variáveis > .conf > padrões ----------
carregar_configuracao() {
  local k
  declare -A do_ambiente=()
  for k in "${CHAVES[@]}"; do
    if [ -n "${!k+x}" ]; then do_ambiente[$k]="${!k}"; fi
  done
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
  fi
  for k in "${!do_ambiente[@]}"; do printf -v "$k" '%s' "${do_ambiente[$k]}"; done

  RUNNER_URL="${RUNNER_URL:-}"
  RUNNER_NOME_GITHUB="${RUNNER_NOME_GITHUB:-}"
  RUNNER_ROTULOS="${RUNNER_ROTULOS:-$RUNNER_NOME}"
  DOCKER_ROOTLESS="${DOCKER_ROOTLESS:-1}"
  RESERVA_MB="${RESERVA_MB:-1024}"
  MEM_MIN_MB="${MEM_MIN_MB:-2048}"
  DISCO_MIN_GB="${DISCO_MIN_GB:-10}"
  MEMORY_MAX_MB="${MEMORY_MAX_MB:-}"
  CPU_QUOTA="${CPU_QUOTA:-}"
  HOSTS_EXTRAS="${HOSTS_EXTRAS:-}"
  PACOTES_EXTRAS="${PACOTES_EXTRAS:-}"
  EXTRAS_SH="${EXTRAS_SH:-}"
  EXTRAS_SHA256="${EXTRAS_SHA256:-}"
  ENV_EXTRAS="${ENV_EXTRAS:-}"
  CPU_QUOTA="${CPU_QUOTA%\%}"
}

validar_configuracao() {
  local k
  for k in RESERVA_MB MEM_MIN_MB DISCO_MIN_GB; do
    if ! [[ "${!k}" =~ ^[0-9]+$ ]]; then erro "$k deve ser um número inteiro."; exit 2; fi
  done
  for k in MEMORY_MAX_MB CPU_QUOTA; do
    if [ -n "${!k}" ] && ! [[ "${!k}" =~ ^[0-9]+$ ]]; then erro "$k deve ser um número inteiro."; exit 2; fi
  done
  if [ "$DOCKER_ROOTLESS" != 0 ] && [ "$DOCKER_ROOTLESS" != 1 ]; then erro "DOCKER_ROOTLESS deve ser 0 ou 1."; exit 2; fi
}

# Grava o .conf (chmod 600) só se o conteúdo mudou; assim a segunda execução não toca em nada.
gravar_configuracao() {
  local novo k tmp
  novo="# runner-vps: configuração da instância $RUNNER_NOME (gerada pelo instalar.sh; pode editar)"$'\n'
  for k in "${CHAVES[@]}"; do novo+="$(printf '%s=%q' "$k" "${!k}")"$'\n'; done
  if [ -f "$CONF" ] && printf '%s' "$novo" | cmp -s - "$CONF"; then return 0; fi
  mkdir -p "$(dirname "$CONF")"
  tmp="$(umask 077; mktemp "$CONF.XXXXXX")"
  printf '%s' "$novo" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONF"
  passo "configuração gravada em $CONF"
}

# ---------- diagnóstico ----------
# Define MEM_EFETIVO_MB e CPU_EFETIVO; imprime os números e o VEREDITO. Devolve 0 (cabe) ou 1 (não cabe).
diagnostico() {
  local meminfo="${MEMINFO_FILE:-/proc/meminfo}" mem_total_mb mem_disp_mb cpus disco_gb caminho f v calculado q
  local outras_mb=0 motivos=()

  mem_total_mb=$(( $(awk '/^MemTotal:/ { print $2 }' "$meminfo") / 1024 ))
  mem_disp_mb=$(( $(awk '/^MemAvailable:/ { print $2 }' "$meminfo") / 1024 ))
  cpus="$("${NPROC_CMD:-nproc}")"

  caminho="$RAIZ/opt/runner-vps"
  while [ ! -e "$caminho" ] && [ "$caminho" != "/" ] && [ "$caminho" != "." ]; do caminho="$(dirname "$caminho")"; done
  disco_gb="$("${DF_CMD:-df}" -BG --output=avail "$caminho" | tail -n 1 | tr -dc '0-9')"

  for f in "$RAIZ"/etc/runner-vps/*.conf; do
    [ -e "$f" ] || continue
    [ "$f" = "$CONF" ] && continue
    v="$(sed -n 's/^MEMORY_MAX_MB=//p' "$f" | head -n 1 | tr -d "'\"")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then outras_mb=$((outras_mb + v)); fi
  done

  calculado=$((mem_disp_mb - RESERVA_MB - outras_mb))
  if [ "$calculado" -lt 0 ]; then calculado=0; fi
  calculado=$((calculado / 256 * 256))
  q=$(((cpus - 1) * 100))
  if [ "$q" -lt 100 ]; then q=100; fi

  MEM_EFETIVO_MB="${MEMORY_MAX_MB:-$calculado}"
  CPU_EFETIVO="${CPU_QUOTA:-$q}"

  passo "memória: ${mem_total_mb} MB no total, ${mem_disp_mb} MB disponíveis, reserva ${RESERVA_MB} MB, outras instâncias ${outras_mb} MB"
  passo "CPUs: $cpus; disco livre em $caminho: ${disco_gb} GB"

  if [ "$MEM_EFETIVO_MB" -lt "$MEM_MIN_MB" ]; then motivos+=("memória (mínimo $MEM_MIN_MB)"); fi
  if [ "$CPU_EFETIVO" -lt 100 ]; then motivos+=("cpu (mínimo 100)"); fi
  if [ "$disco_gb" -lt "$DISCO_MIN_GB" ]; then motivos+=("disco (mínimo $DISCO_MIN_GB GB)"); fi

  if [ "${#motivos[@]}" -gt 0 ]; then
    local IFS=';'
    printf 'VEREDITO: não cabe: %s\n' "${motivos[*]//;/; }"
    return 1
  fi
  printf 'VEREDITO: cabe (MemoryMax=%sM CPUQuota=%s%%)\n' "$MEM_EFETIVO_MB" "$CPU_EFETIVO"
}

# ---------- principal ----------
carregar_configuracao
validar_configuracao

case "$SUB" in
  --status | --remover)
    erro "$SUB ainda não está implementado (Task 3 do plano)."; exit 1 ;;
  --so-checar)
    diagnostico ;;
  "")
    if [ -z "$RUNNER_URL" ]; then erro "RUNNER_URL é obrigatório no primeiro instalar."; exit 2; fi
    if ! [[ "$RUNNER_URL" =~ ^https:// ]]; then erro "RUNNER_URL deve começar com https://."; exit 2; fi
    passo "instância $RUNNER_NOME ($RUNNER_URL)"
    diagnostico || exit 1
    MEMORY_MAX_MB="$MEM_EFETIVO_MB"
    CPU_QUOTA="$CPU_EFETIVO"
    gravar_configuracao
    passo "instalação: próxima task (usuário, Docker rootless, runner e serviço ainda não existem)" ;;
esac
