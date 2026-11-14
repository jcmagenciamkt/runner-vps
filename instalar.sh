#!/usr/bin/env bash
# instalar.sh — instala um runner self-hosted do GitHub Actions numa VPS Linux, em usuário sem privilégio.
# Roda NA VPS, como root, enviado por `ssh … 'bash -s -- [subcomando]'` (veja registrar.sh e docs/design.md).
# As variáveis vêm do ambiente; o stdin não é lido. RUNNER_TOKEN nunca é impresso, gravado nem passado na
# linha de comando: vai ao config.sh pela variável ACTIONS_RUNNER_INPUT_TOKEN, só durante a chamada.
#
# Uso: instalar.sh [--so-checar | --status | --remover]
#   --so-checar mostra o painel de decisão (somente leitura) e termina com o veredito.
set -euo pipefail

passo() { printf '==> %s\n' "$*"; }
aviso() { printf 'AVISO: %s\n' "$*" >&2; }
erro() { printf 'ERRO: %s\n' "$*" >&2; }
uso() {
  cat >&2 <<'USO'
Uso: instalar.sh [--so-checar | --status | --remover]
Variáveis: RUNNER_NOME (obrigatória, [a-z0-9-]+); RUNNER_URL (no primeiro instalar); RUNNER_TOKEN (registro e --remover);
opcionais: RUNNER_NOME_GITHUB, RUNNER_ROTULOS, RUNNER_VERSAO, RUNNER_SHA256, DOCKER_ROOTLESS, RESERVA_MB, MEM_MIN_MB,
DISCO_MIN_GB, MEMORY_MAX_MB, CPU_QUOTA, HOSTS_EXTRAS, PACOTES_EXTRAS, EXTRAS_SH, EXTRAS_SHA256, ENV_EXTRAS.
USO
}

# Chave do repositório apt do Docker, fixada pelo fingerprint publicado na documentação do Docker
# (docs.docker.com/engine/install). DOCKER_APT_FINGERPRINT sobrescreve (só para testes e casos especiais).
DOCKER_APT_FINGERPRINT_PADRAO="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Runner do GitHub com versão e sha256 fixos (release oficial; sobrescreva com RUNNER_VERSAO e RUNNER_SHA256).
RUNNER_VERSAO_PADRAO="2.338.2"
RUNNER_SHA256_X64="baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
RUNNER_SHA256_ARM64="670adb2f268fe21dcbb58b3db0e0aa9d5b3bddfe2c651481336e561ff86de945"

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
USUARIO="runner-$RUNNER_NOME"
HOME_INST="/opt/runner-vps/$RUNNER_NOME" # caminho que vai dentro de arquivos e unidades
HOME_FS="$RAIZ$HOME_INST"                # caminho no disco (igual ao de cima fora dos testes)
UID_INST=""

# Comandos com efeito; cada um tem uma variável que o substitui nos testes.
USERADD="${USERADD_CMD:-useradd}"
USERDEL="${USERDEL_CMD:-userdel}"
LOGINCTL="${LOGINCTL_CMD:-loginctl}"
SYSTEMCTL="${SYSTEMCTL_CMD:-systemctl}"
APT="${APT_CMD:-apt-get}"
CHOWN="${CHOWN_CMD:-chown}"
ROOTLESS="${ROOTLESS_CMD:-dockerd-rootless-setuptool.sh}"

TRABALHO=""
trap '[ -z "$TRABALHO" ] || rm -rf "$TRABALHO"' EXIT
trabalho() {
  if [ -z "$TRABALHO" ]; then TRABALHO="$(mktemp -d)"; chmod 755 "$TRABALHO"; fi
  printf '%s' "$TRABALHO"
}

como_usuario() { # <usuario> <comando…>
  if [ -n "${COMO_USUARIO_CMD:-}" ]; then "$COMO_USUARIO_CMD" "$@"; else runuser -u "$1" -- "${@:2}"; fi
}
baixar() { # <url> <destino>
  if [ -n "${BAIXAR_CMD:-}" ]; then "$BAIXAR_CMD" "$1" "$2"; else curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"; fi
}
uid_do_usuario() { "${ID_CMD:-id}" -u "$USUARIO" 2>/dev/null; }
user_systemctl() { "$SYSTEMCTL" --user -M "$USUARIO@" "$@"; }
ambiente_do_usuario() { # imprime as atribuições para `env`, uma por linha
  printf '%s\n' "HOME=$HOME_INST" "XDG_RUNTIME_DIR=/run/user/$UID_INST" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_INST/bus"
}

# gravar_se_mudou <destino> [modo] < conteúdo — grava só se o conteúdo mudou (preserva o mtime).
# Define ALTEROU=1 se gravou, 0 se já estava igual.
ALTEROU=0
gravar_se_mudou() {
  local destino="$1" modo="${2:-644}" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [ -f "$destino" ] && cmp -s "$tmp" "$destino"; then
    ALTEROU=0
  else
    mkdir -p "$(dirname "$destino")"
    install -m "$modo" "$tmp" "$destino"
    ALTEROU=1
  fi
  rm -f "$tmp"
}

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
  RUNNER_VERSAO="${RUNNER_VERSAO:-}"
  RUNNER_SHA256="${RUNNER_SHA256:-}"
}

validar_configuracao() {
  local k par
  for k in RESERVA_MB MEM_MIN_MB DISCO_MIN_GB; do
    if ! [[ "${!k}" =~ ^[0-9]+$ ]]; then erro "$k deve ser um número inteiro."; exit 2; fi
  done
  for k in MEMORY_MAX_MB CPU_QUOTA; do
    if [ -n "${!k}" ] && ! [[ "${!k}" =~ ^[0-9]+$ ]]; then erro "$k deve ser um número inteiro."; exit 2; fi
  done
  if [ "$DOCKER_ROOTLESS" != 0 ] && [ "$DOCKER_ROOTLESS" != 1 ]; then erro "DOCKER_ROOTLESS deve ser 0 ou 1."; exit 2; fi
  if ! [[ "$PACOTES_EXTRAS" =~ ^[A-Za-z0-9.+:_\ -]*$ ]]; then erro "PACOTES_EXTRAS: só nomes de pacotes separados por espaço."; exit 2; fi
  if [[ "$HOSTS_EXTRAS" == *$'\n'* ]]; then erro "HOSTS_EXTRAS deve ser uma linha só."; exit 2; fi
  if [ -n "$ENV_EXTRAS" ]; then
    local partes
    IFS=';' read -ra partes <<< "$ENV_EXTRAS"
    for par in "${partes[@]}"; do
      par="${par#"${par%%[![:space:]]*}"}"
      if [ -n "$par" ] && ! [[ "$par" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then erro "ENV_EXTRAS: '$par' não é CHAVE=valor."; exit 2; fi
    done
  fi
  if [[ "$EXTRAS_SH" == https://* ]]; then
    if ! [[ "$EXTRAS_SHA256" =~ ^[0-9a-f]{64}$ ]]; then erro "EXTRAS_SH por URL exige EXTRAS_SHA256 (64 hexadecimais)."; exit 2; fi
  elif [ -n "$EXTRAS_SH" ] && [[ "$EXTRAS_SH" != /* ]]; then
    erro "EXTRAS_SH deve ser um caminho absoluto na VPS ou uma URL https://."; exit 2
  fi
  if [ -n "$RUNNER_VERSAO" ] && [ -z "$RUNNER_SHA256" ]; then erro "RUNNER_VERSAO exige RUNNER_SHA256 da mesma release."; exit 2; fi
  if [ -n "$RUNNER_SHA256" ] && ! [[ "$RUNNER_SHA256" =~ ^[0-9a-f]{64}$ ]]; then erro "RUNNER_SHA256 deve ter 64 hexadecimais."; exit 2; fi
}

# Grava o .conf (chmod 600) só se o conteúdo mudou; assim a segunda execução não toca em nada.
gravar_configuracao() {
  local novo k
  novo="# runner-vps: configuração da instância $RUNNER_NOME (gerada pelo instalar.sh; pode editar)"$'\n'
  for k in "${CHAVES[@]}"; do novo+="$(printf '%s=%q' "$k" "${!k}")"$'\n'; done
  printf '%s' "$novo" | gravar_se_mudou "$CONF" 600
  if [ "$ALTEROU" = 1 ]; then passo "configuração gravada em $CONF"; fi
}

# ---------- diagnóstico ----------
tem_systemd() { [ -d "$RAIZ/run/systemd/system" ]; }
tem_apt() { command -v "$APT" > /dev/null 2>&1; }
# max_user_namespaces do kernel: imprime o número, ou nada se o sistema não informa.
valor_userns() {
  local f="${USERNS_FILE:-/proc/sys/user/max_user_namespaces}"
  if [ -r "$f" ]; then tr -dc '0-9' < "$f"; fi
}
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
  # Só bloqueiam quando o problema é detectado de forma positiva (dado ausente = desconhecido, não bloqueia).
  if ! tem_systemd; then motivos+=("systemd ausente"); fi
  if ! tem_apt; then motivos+=("apt-get ausente"); fi
  if [ "$DOCKER_ROOTLESS" = 1 ] && [ "$(valor_userns)" = 0 ]; then motivos+=("user namespaces desligados (o rootless exige)"); fi

  if [ "${#motivos[@]}" -gt 0 ]; then
    local IFS=';'
    printf 'VEREDITO: não cabe: %s\n' "${motivos[*]//;/; }"
    return 1
  fi
  printf 'VEREDITO: cabe (MemoryMax=%sM CPUQuota=%s%%)\n' "$MEM_EFETIVO_MB" "$CPU_EFETIVO"
}

# ---------- painel de decisão (somente leitura) ----------
# Estado do serviço runner-vps de uma instância: "active", "inactive"… ou "sem usuário".
estado_do_servico() { # <nome da instância>
  local usuario="runner-$1" estado
  if ! "${ID_CMD:-id}" -u "$usuario" > /dev/null 2>&1; then printf 'sem usuário'; return 0; fi
  estado="$("$SYSTEMCTL" --user -M "$usuario@" is-active runner-vps 2> /dev/null || true)"
  printf '%s' "${estado:-desconhecido}"
}

# Lê RUNNER_URL, MEMORY_MAX_MB e CPU_QUOTA de um .conf sem contaminar o ambiente: "url|mem|cpu".
campos_da_instancia() { # <arquivo .conf>
  # shellcheck disable=SC1090
  ( . "$1"; printf '%s|%s|%s' "${RUNNER_URL:-}" "${MEMORY_MAX_MB:-}" "${CPU_QUOTA:-}" )
}

# Tudo o que a pessoa precisa para decidir se instala: sistema, Docker rootless, instâncias, estado desta
# instância, avisos e, por último, os recursos e o veredito. Não cria, não grava e não reinicia nada.
painel() {
  local os_release="${OS_RELEASE_FILE:-/etc/os-release}" meminfo="${MEMINFO_FILE:-/proc/meminfo}"
  local sistema arq kernel carga userns restricao f n url mem cpu estado mem_txt cpu_txt marca url_conf="" total=0 quantas=0 swap_mb
  local -a avisos=()

  printf '== Sistema ==\n'
  sistema="desconhecido"
  if [ -f "$os_release" ]; then
    # shellcheck disable=SC1090
    sistema="$(. "$os_release"; printf '%s' "${PRETTY_NAME:-${ID:-desconhecido} ${VERSION_CODENAME:-}}")"
  fi
  arq="$("${UNAME_CMD:-uname}" -m 2> /dev/null || printf desconhecida)"
  kernel="$("${UNAME_CMD:-uname}" -r 2> /dev/null || printf desconhecido)"
  carga="desconhecida"
  if [ -r "${LOADAVG_FILE:-/proc/loadavg}" ]; then carga="$(awk '{ print $1, $2, $3 }' "${LOADAVG_FILE:-/proc/loadavg}")"; fi
  printf 'sistema: %s\narquitetura: %s\nkernel: %s\n' "$sistema" "$arq" "$kernel"
  if tem_systemd; then printf 'systemd: sim\n'; else printf 'systemd: NÃO (ausente)\n'; fi
  if tem_apt; then printf 'apt-get: sim\n'; else printf 'apt-get: NÃO (ausente)\n'; fi
  printf 'carga (1, 5, 15 min): %s\n' "$carga"

  printf '\n== Docker rootless ==\n'
  if [ "$DOCKER_ROOTLESS" = 1 ]; then
    printf 'Docker rootless: ligado (DOCKER_ROOTLESS=1)\n'
    if command -v "${DOCKER_CMD:-docker}" > /dev/null 2>&1; then printf 'docker: instalado\n'
    else printf 'docker: não instalado (o instalador instala do repositório oficial)\n'; fi
    if grep -rqs 'download.docker.com' "$RAIZ/etc/apt/sources.list" "$RAIZ/etc/apt/sources.list.d" 2> /dev/null; then
      printf 'repositório apt do Docker: configurado\n'
    else
      printf 'repositório apt do Docker: não configurado (o instalador configura, com a chave fixada)\n'
    fi
    userns="$(valor_userns)"
    if [ -z "$userns" ]; then printf 'user namespaces: desconhecido\n'
    elif [ "$userns" = 0 ]; then printf 'user namespaces: DESLIGADOS (max_user_namespaces=0)\n'
    else printf 'user namespaces: ok (max_user_namespaces=%s)\n' "$userns"; fi
    if command -v "${NEWUIDMAP_CMD:-newuidmap}" > /dev/null 2>&1; then printf 'uidmap (newuidmap): presente\n'
    else printf 'uidmap (newuidmap): ausente (o instalador instala)\n'; fi
    restricao=""
    if [ -r "${APPARMOR_USERNS_FILE:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}" ]; then
      restricao="$(tr -dc '0-9' < "${APPARMOR_USERNS_FILE:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}")"
    fi
    if [ "$restricao" = 1 ]; then
      avisos+=("o AppArmor restringe user namespaces (apparmor_restrict_unprivileged_userns=1): o rootless pode exigir um perfil; se o check do rootless falhar, o instalador para com o motivo")
    fi
  else
    printf 'Docker rootless: desligado (DOCKER_ROOTLESS=0)\n'
  fi

  printf '\n== Instâncias nesta VPS ==\n'
  for f in "$RAIZ"/etc/runner-vps/*.conf; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .conf)"
    IFS='|' read -r url mem cpu <<< "$(campos_da_instancia "$f")"
    estado="$(estado_do_servico "$n")"
    mem_txt="(a calcular na instalação)"; if [ -n "$mem" ]; then mem_txt="${mem}M"; fi
    cpu_txt="(a calcular na instalação)"; if [ -n "$cpu" ]; then cpu_txt="${cpu}%"; fi
    marca=""; if [ "$f" = "$CONF" ]; then marca=" (esta)"; fi
    printf '%s%s: %s; MemoryMax=%s; CPUQuota=%s; serviço: %s\n' "$n" "$marca" "${url:-sem URL}" "$mem_txt" "$cpu_txt" "$estado"
    if [[ "$mem" =~ ^[0-9]+$ ]]; then total=$((total + mem)); fi
    quantas=$((quantas + 1))
  done
  if [ "$quantas" -eq 0 ]; then printf 'nenhuma instância instalada ainda\n'
  else printf 'memória reservada pelas instâncias: %s MB\n' "$total"; fi

  printf '\n== Esta instância (%s) ==\n' "$RUNNER_NOME"
  if [ -f "$CONF" ]; then IFS='|' read -r url_conf _ _ <<< "$(campos_da_instancia "$CONF")"; fi
  if UID_INST="$(uid_do_usuario)"; then
    if [ -f "$CONF" ]; then
      printf 'situação: já instalada (rodar de novo reaplica a configuração; nada muda nem reinicia se nada mudou)\n'
    else
      printf 'situação: incompleta (o usuário existe, mas falta a configuração em /etc/runner-vps)\n'
    fi
    printf 'usuário: %s (uid %s)\n' "$USUARIO" "$UID_INST"
    printf 'serviço runner-vps: %s\n' "$(estado_do_servico "$RUNNER_NOME")"
    if [ -e "$HOME_FS/runner/.runner" ]; then printf 'registro no GitHub: .runner presente\n'
    else printf 'registro no GitHub: .runner ausente\n'; fi
  else
    if [ -f "$CONF" ]; then
      printf 'situação: incompleta (a configuração existe, mas falta o usuário %s)\n' "$USUARIO"
    else
      printf 'situação: instalação nova (nada instalado ainda)\n'
    fi
    printf 'usuário: %s (ausente)\n' "$USUARIO"
  fi
  if [ -n "$url_conf" ]; then printf 'URL configurada: %s\n' "$url_conf"; fi
  if [ -n "$url_conf" ] && [ -n "$RUNNER_URL" ] && [ "$url_conf" != "$RUNNER_URL" ]; then
    avisos+=("a instância já está configurada para $url_conf, mas a URL informada é $RUNNER_URL")
  fi

  printf '\n== Avisos ==\n'
  if [ "${#avisos[@]}" -eq 0 ]; then printf 'nenhum aviso\n'
  else for n in "${avisos[@]}"; do printf -- '- %s\n' "$n"; done; fi

  printf '\n== Recursos e veredito ==\n'
  swap_mb="$(awk '/^SwapTotal:/ { print int($2 / 1024) }' "$meminfo" 2> /dev/null || true)"
  printf 'swap: %s MB\n' "${swap_mb:-0}"
  diagnostico
}

# ---------- usuário ----------
criar_usuario() {
  if UID_INST="$(uid_do_usuario)"; then
    passo "usuário $USUARIO já existe (uid $UID_INST)"
    return 0
  fi
  passo "criando o usuário $USUARIO (sem sudo, sem grupo docker)"
  mkdir -p "$(dirname "$HOME_FS")"
  "$USERADD" --create-home --home-dir "$HOME_FS" --shell /bin/bash --user-group "$USUARIO"
  UID_INST="$(uid_do_usuario)"
}

# Uma faixa de 65536 ids para o usuário, sem colidir com as existentes (começa em 100000).
garantir_faixa_subid() { # <subuid|subgid>
  local arq="$RAIZ/etc/$1" inicio
  if [ ! -e "$arq" ]; then : > "$arq"; fi
  if grep -q "^$USUARIO:" "$arq"; then return 0; fi
  inicio="$(awk -F: 'BEGIN { m = 100000 } { f = $2 + $3; if (f > m) m = f } END { print m }' "$arq")"
  printf '%s:%s:65536\n' "$USUARIO" "$inicio" >> "$arq"
  passo "faixa de $1 para $USUARIO: $inicio (65536 ids)"
}

ligar_linger() {
  if [ ! -e "$RAIZ/var/lib/systemd/linger/$USUARIO" ]; then "$LOGINCTL" enable-linger "$USUARIO"; fi
  "$SYSTEMCTL" start "user@$UID_INST.service"
}

# ---------- pacotes, Docker rootless ----------
apt_instalar() {
  if ! DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "$@"; then
    "$APT" update
    DEBIAN_FRONTEND=noninteractive "$APT" install -y --no-install-recommends "$@"
  fi
}

# Configura o repositório apt oficial do Docker (Debian e Ubuntu), com a chave fixada pelo fingerprint.
# O arquivo baixado só vale se tiver EXATAMENTE uma chave primária e ela for a esperada: o apt confia em todas as
# chaves do arquivo apontado por Signed-By, então só a chave fixada é exportada para o chaveiro.
configurar_repositorio_docker() {
  local os_release="${OS_RELEASE_FILE:-/etc/os-release}" id codename esperado dir bruto chaveiro primarias=()
  if grep -rqs 'download.docker.com' "$RAIZ/etc/apt/sources.list" "$RAIZ/etc/apt/sources.list.d" 2> /dev/null; then
    passo "repositório apt do Docker já configurado"
    return 0
  fi
  if [ ! -f "$os_release" ]; then erro "não encontrei $os_release para descobrir a distribuição."; exit 1; fi
  # shellcheck disable=SC1090
  id="$(. "$os_release"; printf '%s' "${ID:-}")"
  # shellcheck disable=SC1090
  codename="$(. "$os_release"; if [ "${ID:-}" = ubuntu ]; then printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"; else printf '%s' "${VERSION_CODENAME:-}"; fi)"
  case "$id" in
    debian | ubuntu) ;;
    *) erro "distribuição sem suporte para configurar o repositório do Docker: '${id:-desconhecida}'. Configure o repositório oficial à mão (docs.docker.com/engine/install) e rode de novo."; exit 1 ;;
  esac
  if [ -z "$codename" ]; then erro "não consegui descobrir o codinome da distribuição em $os_release."; exit 1; fi
  esperado="$(printf '%s' "${DOCKER_APT_FINGERPRINT:-$DOCKER_APT_FINGERPRINT_PADRAO}" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"

  passo "configurando o repositório apt do Docker ($id $codename)"
  apt_instalar ca-certificates curl gnupg
  dir="$(trabalho)/gnupg"
  mkdir -p "$dir"; chmod 700 "$dir"
  bruto="$(trabalho)/docker-gpg.asc"
  if ! baixar "https://download.docker.com/linux/$id/gpg" "$bruto"; then
    erro "não consegui baixar a chave do repositório do Docker."; exit 1
  fi
  if ! gpg --homedir "$dir" --batch --quiet --import "$bruto" 2> /dev/null; then
    erro "o arquivo baixado não é uma chave GPG válida; o repositório do Docker não foi configurado."; exit 1
  fi
  mapfile -t primarias < <(gpg --homedir "$dir" --batch --with-colons --list-keys 2> /dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }')
  if [ "${#primarias[@]}" -ne 1 ] || [ "${primarias[0]}" != "$esperado" ]; then
    erro "o fingerprint da chave baixada (${primarias[*]:-nenhuma}) não é o esperado ($esperado) ou o arquivo tem mais de uma chave; o repositório do Docker não foi configurado."
    exit 1
  fi
  chaveiro="$(trabalho)/docker.gpg"
  gpg --homedir "$dir" --batch --export "$esperado" > "$chaveiro" 2> /dev/null
  gpgconf --homedir "$dir" --kill all 2> /dev/null || true
  gravar_se_mudou "$RAIZ/etc/apt/keyrings/docker.gpg" 644 < "$chaveiro"
  gravar_se_mudou "$RAIZ/etc/apt/sources.list.d/docker.sources" 644 <<FONTE
Types: deb
URIs: https://download.docker.com/linux/$id
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.gpg
FONTE
  "$APT" update
}

instalar_pacotes_docker() {
  local pacotes=(uidmap dbus-user-session slirp4netns)
  if ! command -v "$ROOTLESS" > /dev/null 2>&1; then
    configurar_repositorio_docker
    pacotes+=(docker-ce docker-ce-rootless-extras docker-compose-plugin)
  fi
  passo "pacotes para o Docker rootless: ${pacotes[*]}"
  apt_instalar "${pacotes[@]}"
  if ! command -v "$ROOTLESS" > /dev/null 2>&1; then
    erro "$ROOTLESS não foi encontrado depois de instalar os pacotes do Docker."
    exit 1
  fi
}

configurar_rootless() {
  local saida amb=()
  mapfile -t amb < <(ambiente_do_usuario)
  if ! saida="$(como_usuario "$USUARIO" env "${amb[@]}" "$ROOTLESS" check 2>&1)"; then
    erro "Docker rootless não funciona nesta VPS: $saida"
    erro "Não existe alternativa com o socket do Docker de root. Use outra máquina ou DOCKER_ROOTLESS=0."
    exit 1
  fi
  if [ ! -e "$HOME_FS/.config/systemd/user/docker.service" ]; then
    passo "instalando o Docker rootless do usuário"
    como_usuario "$USUARIO" env "${amb[@]}" "$ROOTLESS" install
  fi
  user_systemctl enable --now docker
}

# ---------- runner ----------
instalar_runner() {
  local arquitetura versao sha url dir
  if [ -x "$HOME_FS/runner/run.sh" ] && [ -e "$HOME_FS/runner/config.sh" ]; then
    passo "runner já instalado em $HOME_INST/runner (ele se atualiza sozinho)"
    return 0
  fi
  case "$(uname -m)" in
    x86_64) arquitetura=x64; sha="$RUNNER_SHA256_X64" ;;
    aarch64 | arm64) arquitetura=arm64; sha="$RUNNER_SHA256_ARM64" ;;
    *) erro "arquitetura não suportada: $(uname -m)"; exit 1 ;;
  esac
  versao="${RUNNER_VERSAO:-$RUNNER_VERSAO_PADRAO}"
  if [ -n "$RUNNER_SHA256" ]; then sha="$RUNNER_SHA256"; fi
  url="https://github.com/actions/runner/releases/download/v$versao/actions-runner-linux-$arquitetura-$versao.tar.gz"
  dir="$(trabalho)"
  passo "baixando o runner $versao"
  baixar "$url" "$dir/runner.tar.gz"
  if ! printf '%s  %s\n' "$sha" "$dir/runner.tar.gz" | sha256sum -c --status -; then
    erro "o sha256 do runner baixado não confere com o esperado; nada foi extraído."
    exit 1
  fi
  chmod 644 "$dir/runner.tar.gz"
  como_usuario "$USUARIO" mkdir -p "$HOME_FS/runner"
  como_usuario "$USUARIO" tar -xzf "$dir/runner.tar.gz" -C "$HOME_FS/runner"
  if [ -f "$HOME_FS/runner/bin/installdependencies.sh" ]; then
    passo "instalando as dependências do runner"
    bash "$HOME_FS/runner/bin/installdependencies.sh"
  fi
}

# O token vai pelo ambiente (ACTIONS_RUNNER_INPUT_TOKEN), nunca pela linha de comando.
chamar_config() { # <argumentos do config.sh…>; usa RUNNER_TOKEN
  local cfg="${CONFIG_CMD:-./config.sh}" status=0
  export ACTIONS_RUNNER_INPUT_TOKEN="$RUNNER_TOKEN"
  como_usuario "$USUARIO" env "HOME=$HOME_INST" bash -c 'cd "$1" && shift && exec "$@"' _ "$HOME_FS/runner" "$cfg" "$@" || status=$?
  unset ACTIONS_RUNNER_INPUT_TOKEN
  return "$status"
}

registrar_runner() {
  if [ -z "${RUNNER_TOKEN:-}" ]; then
    aviso "RUNNER_TOKEN ausente: registro pulado (o resto da instalação segue)."
    return 0
  fi
  passo "registrando o runner ${RUNNER_NOME_GITHUB:-$RUNNER_NOME} em $RUNNER_URL"
  if ! chamar_config --unattended --replace --url "$RUNNER_URL" --name "${RUNNER_NOME_GITHUB:-$RUNNER_NOME}" \
    --labels "$RUNNER_ROTULOS" --work _work; then
    erro "o registro do runner falhou (config.sh); confira a URL, o token (uso único, expira em 1 hora) e as permissões."
    exit 1
  fi
}

# ---------- arquivos da instância ----------
# Cópia do gancho-fim.sh do repositório (testes/test_gancho.sh confere que são idênticos).
conteudo_gancho() {
  cat <<'GANCHO'
#!/usr/bin/env bash
# gancho-fim.sh — gancho de fim de job do runner-vps (ACTIONS_RUNNER_HOOK_JOB_COMPLETED).
# Roda na VPS, como o usuário do runner. Derruba os projetos do Docker Compose que o job deixou, faz o prune
# de camadas com mais de 24 h e grava uma linha em $HOME/runner-vps.log. Sai SEMPRE com 0: um gancho que
# falha não pode derrubar o job nem o runner. Nunca usa o socket do Docker de root nem eleva privilégios.
set -euo pipefail
trap 'exit 0' EXIT

passo() { printf '==> %s\n' "$*"; }

docker_cmd="${DOCKER_CMD:-docker}"
log="${LOG_FILE:-$HOME/runner-vps.log}"
agora="${AGORA:-$(date +%s)}"
docker_estado=pulado

# O Docker rootless do usuário só existe se o instalador deixou DOCKER_HOST no .env do runner.
if [ -n "${DOCKER_HOST:-}" ]; then
  docker_estado=ok
  passo "limpando o Docker do job"
  projetos="$("$docker_cmd" compose ls -q 2> /dev/null)" || { docker_estado=falhou; projetos=""; }
  # O daemon é só do CI: todo projeto listado aqui é do job.
  while IFS= read -r projeto; do
    if [ -z "$projeto" ]; then continue; fi
    "$docker_cmd" compose -p "$projeto" down -v --remove-orphans > /dev/null 2>&1 || docker_estado=falhou
  done <<< "$projetos"
  "$docker_cmd" system prune -f --filter until=24h > /dev/null 2>&1 || docker_estado=falhou
fi

disco="$("${DF_CMD:-df}" -BG --output=avail "${HOME:-/}" 2> /dev/null | tail -n 1 | tr -d ' ')" || disco=""
data="$(date -u -d "@$agora" +%Y-%m-%dT%H:%M:%SZ)" || data="$agora"
printf '%s job=%s run=%s docker=%s disco=%s\n' "$data" "${GITHUB_JOB:-?}" "${GITHUB_RUN_ID:-?}" "$docker_estado" "${disco:-?}" \
  >> "$log" 2> /dev/null || passo "não foi possível gravar $log"
GANCHO
}

conteudo_env() {
  local partes par
  if [ "$DOCKER_ROOTLESS" = 1 ]; then printf 'DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$UID_INST"; fi
  printf 'PATH=%s/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' "$HOME_INST"
  printf 'ACTIONS_RUNNER_HOOK_JOB_COMPLETED=%s/bin/gancho-fim.sh\n' "$HOME_INST"
  if [ -n "$ENV_EXTRAS" ]; then
    IFS=';' read -ra partes <<< "$ENV_EXTRAS"
    for par in "${partes[@]}"; do
      par="${par#"${par%%[![:space:]]*}"}"
      if [ -n "$par" ]; then printf '%s\n' "$par"; fi
    done
  fi
}

conteudo_unidade() {
  cat <<UNIDADE
[Unit]
Description=Runner do GitHub Actions (runner-vps, instância $RUNNER_NOME)
UNIDADE
  if [ "$DOCKER_ROOTLESS" = 1 ]; then printf 'After=docker.service\n'; fi
  cat <<UNIDADE

[Service]
ExecStart=$HOME_INST/runner/run.sh
WorkingDirectory=$HOME_INST/runner
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
UNIDADE
}

conteudo_fatia() {
  cat <<FATIA
[Slice]
MemoryMax=${MEM_EFETIVO_MB}M
MemorySwapMax=0
CPUQuota=${CPU_EFETIVO}%
TasksMax=4096
FATIA
}

SLICE_ALTEROU=0
UNIDADE_ALTEROU=0
escrever_arquivos() {
  mkdir -p "$HOME_FS/bin" "$HOME_FS/.config/systemd/user"
  gravar_se_mudou "$HOME_FS/bin/gancho-fim.sh" 755 < <(conteudo_gancho)
  if [ "$ALTEROU" = 1 ]; then passo "gancho de fim de job gravado"; fi
  gravar_se_mudou "$HOME_FS/runner/.env" 644 < <(conteudo_env)
  if [ "$ALTEROU" = 1 ]; then passo ".env do runner gravado"; fi
  gravar_se_mudou "$HOME_FS/.config/systemd/user/runner-vps.service" 644 < <(conteudo_unidade)
  UNIDADE_ALTEROU="$ALTEROU"
  if [ "$ALTEROU" = 1 ]; then passo "unidade runner-vps.service gravada"; fi
  gravar_se_mudou "$RAIZ/etc/systemd/system/user-$UID_INST.slice.d/runner-vps.conf" 644 < <(conteudo_fatia)
  SLICE_ALTEROU="$ALTEROU"
  if [ "$ALTEROU" = 1 ]; then passo "limites da fatia gravados (MemoryMax=${MEM_EFETIVO_MB}M CPUQuota=${CPU_EFETIVO}%)"; fi
  "$CHOWN" -R "$USUARIO:$USUARIO" "$HOME_FS/bin" "$HOME_FS/.config"
  "$CHOWN" "$USUARIO:$USUARIO" "$HOME_FS/runner/.env"
}

# /etc/hosts: uma linha marcada por instância; trocar HOSTS_EXTRAS troca a linha, apagá-lo a remove.
atualizar_hosts() {
  local arq="$RAIZ/etc/hosts" marca="# runner-vps $RUNNER_NOME" tmp
  if [ ! -f "$arq" ] && [ -z "$HOSTS_EXTRAS" ]; then return 0; fi
  tmp="$(mktemp)"
  { grep -vE " # runner-vps $RUNNER_NOME\$" "$arq" 2> /dev/null || true; } > "$tmp"
  if [ -n "$HOSTS_EXTRAS" ]; then printf '%s %s\n' "$HOSTS_EXTRAS" "$marca" >> "$tmp"; fi
  if ! cmp -s "$tmp" "$arq" 2> /dev/null; then
    cat "$tmp" > "$arq"
    passo "/etc/hosts atualizado (linha marcada '$marca')"
  fi
  rm -f "$tmp"
}

ativar_servicos() {
  if [ "$SLICE_ALTEROU" = 1 ]; then "$SYSTEMCTL" daemon-reload; fi
  if [ "$UNIDADE_ALTEROU" = 1 ]; then user_systemctl daemon-reload; fi
  if [ -e "$HOME_FS/runner/.runner" ]; then
    user_systemctl enable --now runner-vps
  else
    user_systemctl enable runner-vps
    aviso "o runner ainda não está registrado: o serviço foi habilitado, mas não iniciado. Rode de novo com RUNNER_TOKEN."
  fi
}

executar_extras() {
  local script dir
  if [ -z "$EXTRAS_SH" ]; then return 0; fi
  if [[ "$EXTRAS_SH" == https://* ]]; then
    dir="$(trabalho)"
    script="$dir/extras.sh"
    baixar "$EXTRAS_SH" "$script"
    if ! printf '%s  %s\n' "$EXTRAS_SHA256" "$script" | sha256sum -c --status -; then
      erro "o sha256 de EXTRAS_SH não confere; o script não foi executado."
      exit 1
    fi
  else
    script="$EXTRAS_SH"
    if [ ! -f "$script" ]; then erro "EXTRAS_SH não encontrado: $script"; exit 1; fi
  fi
  passo "executando EXTRAS_SH"
  bash "$script"
}

# ---------- estado ----------
mostrar_estado() {
  local estado quer limites log
  passo "estado da instância $RUNNER_NOME"
  if ! UID_INST="$(uid_do_usuario)"; then
    printf 'usuário: %s (ausente)\n' "$USUARIO"
    return 1
  fi
  printf 'usuário: %s (uid %s)\n' "$USUARIO" "$UID_INST"
  estado="$(user_systemctl is-active runner-vps 2> /dev/null || true)"
  printf 'serviço runner-vps: %s\n' "${estado:-desconhecido}"
  if [ "$DOCKER_ROOTLESS" = 1 ]; then
    estado="$(user_systemctl is-active docker 2> /dev/null || true)"
    printf 'serviço docker: %s\n' "${estado:-desconhecido}"
  else
    printf 'serviço docker: desligado (DOCKER_ROOTLESS=0)\n'
  fi
  quer="$RAIZ/etc/systemd/system/user-$UID_INST.slice.d/runner-vps.conf"
  if [ -f "$quer" ]; then
    limites="$(grep -E '^(MemoryMax|MemorySwapMax|CPUQuota|TasksMax)=' "$quer" | tr '\n' ' ')"
    printf 'limites: %s\n' "$limites"
  else
    printf 'limites: não gravados\n'
  fi
  if [ -e "$HOME_FS/runner/.runner" ]; then printf 'registro: .runner presente\n'; else printf 'registro: .runner ausente\n'; fi
  if [ -e "$HOME_FS/runner/.credentials" ]; then printf 'registro: .credentials presente\n'; else printf 'registro: .credentials ausente\n'; fi
  if [ -s "$HOME_FS/runner-vps.log" ]; then
    log="$(tail -n 1 "$HOME_FS/runner-vps.log")"
    printf 'último registro do log: %s\n' "$log"
  else
    printf 'último registro do log: (vazio)\n'
  fi
}

# ---------- remoção ----------
arquivos_do_usuario() { # arquivos do usuário fora do HOME (para decidir se dá para apagar o usuário)
  if [ -n "${ARQUIVOS_DO_USUARIO_CMD:-}" ]; then
    "$ARQUIVOS_DO_USUARIO_CMD" "$USUARIO"
  else
    find / -xdev -user "$USUARIO" -not -path "$HOME_INST" -not -path "$HOME_INST/*" -not -path '/proc/*' \
      -not -path '/run/user/*' -not -path '/var/mail/*' 2> /dev/null | head -n 5
  fi
}

remover_instancia() {
  local tem_usuario=0 amb=() restantes
  if [ -z "${RUNNER_TOKEN:-}" ]; then
    erro "--remover precisa de RUNNER_TOKEN (token de remoção: gh api -X POST …/actions/runners/remove-token)."; exit 2
  fi
  if UID_INST="$(uid_do_usuario)"; then tem_usuario=1; fi
  if [ "$tem_usuario" = 0 ] && [ ! -f "$CONF" ] && [ ! -d "$HOME_FS" ]; then
    erro "a instância $RUNNER_NOME não existe nesta VPS."; exit 1
  fi
  case "$HOME_FS" in "$RAIZ"/opt/runner-vps/?*) ;; *) erro "caminho do HOME inesperado: $HOME_FS"; exit 1 ;; esac

  if [ "$tem_usuario" = 1 ]; then
    mapfile -t amb < <(ambiente_do_usuario)
    if [ -e "$HOME_FS/runner/.runner" ]; then
      passo "removendo o registro do runner no GitHub"
      if ! chamar_config remove; then
        erro "config.sh remove falhou; nada foi apagado. Confira o token de remoção (uso único, expira em 1 hora)."
        exit 1
      fi
    fi
    passo "parando e desabilitando os serviços"
    user_systemctl disable --now runner-vps || aviso "não foi possível parar o runner-vps (talvez já esteja parado)."
    if [ "$DOCKER_ROOTLESS" = 1 ]; then
      user_systemctl disable --now docker || aviso "não foi possível parar o docker do usuário."
      como_usuario "$USUARIO" env "${amb[@]}" "$ROOTLESS" uninstall || aviso "dockerd-rootless-setuptool uninstall falhou."
    fi
    "$LOGINCTL" disable-linger "$USUARIO"
    "$LOGINCTL" terminate-user "$USUARIO" || true
  fi
  unset RUNNER_TOKEN

  passo "apagando os arquivos da instância"
  rm -rf "${HOME_FS:?}"
  rm -f "$CONF"
  if [ -n "$UID_INST" ]; then
    rm -f "$RAIZ/etc/systemd/system/user-$UID_INST.slice.d/runner-vps.conf"
    rmdir "$RAIZ/etc/systemd/system/user-$UID_INST.slice.d" 2> /dev/null || true
    "$SYSTEMCTL" daemon-reload
  fi
  HOSTS_EXTRAS=""
  atualizar_hosts

  if [ "$tem_usuario" = 1 ]; then
    restantes="$(arquivos_do_usuario || true)"
    if [ -n "$restantes" ]; then
      aviso "usuário mantido: $USUARIO tem arquivos fora do HOME (por exemplo: $(printf '%s' "$restantes" | head -n 1)). Apague-o à mão depois de conferir."
    else
      "$USERDEL" "$USUARIO"
    fi
  fi
  passo "instância $RUNNER_NOME removida (as linhas de /etc/subuid e /etc/subgid ficam; são inofensivas)"
}

# ---------- principal ----------
carregar_configuracao
validar_configuracao

case "$SUB" in
  --status)
    mostrar_estado ;;
  --remover)
    remover_instancia ;;
  --so-checar)
    painel ;;
  "")
    if [ -z "$RUNNER_URL" ]; then erro "RUNNER_URL é obrigatório no primeiro instalar."; exit 2; fi
    if ! [[ "$RUNNER_URL" =~ ^https:// ]]; then erro "RUNNER_URL deve começar com https://."; exit 2; fi
    passo "instância $RUNNER_NOME ($RUNNER_URL)"
    diagnostico || exit 1
    MEMORY_MAX_MB="$MEM_EFETIVO_MB"
    CPU_QUOTA="$CPU_EFETIVO"
    gravar_configuracao
    criar_usuario
    if [ "$DOCKER_ROOTLESS" = 1 ]; then
      garantir_faixa_subid subuid
      garantir_faixa_subid subgid
      instalar_pacotes_docker
    fi
    ligar_linger
    if [ "$DOCKER_ROOTLESS" = 1 ]; then configurar_rootless; fi
    if [ -n "$PACOTES_EXTRAS" ]; then
      read -ra extras <<< "$PACOTES_EXTRAS"
      passo "pacotes extras: ${extras[*]}"
      apt_instalar "${extras[@]}"
    fi
    instalar_runner
    registrar_runner
    unset RUNNER_TOKEN
    escrever_arquivos
    atualizar_hosts
    ativar_servicos
    executar_extras
    mostrar_estado ;;
esac
