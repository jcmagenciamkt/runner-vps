#!/usr/bin/env bash
# registrar.sh — instala, confere, mostra ou remove um runner numa VPS, a partir da sua máquina.
#
# Gera o token de registro pela API do GitHub (gh api), monta as variáveis do instalar.sh e envia
# tudo pelo SSH. O token vai pelo fluxo de entrada do SSH, junto com o script: nunca passa pela
# linha de comando (ps), pelo histórico do shell nem por arquivo.
#
# Uso:
#   registrar.sh --vps root@<vps>[:porta] | <alias do ~/.ssh/config> (--repo <dono>/<repo> | --org <org>) --nome <nome> [opções]
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
#   --quieto                 não imprime as linhas de andamento (==>); só o que o instalador responde
#   -h, --help
#
# Pré-requisitos: gh autenticado (gh auth status) com acesso de administrador ao repositório
# (ou à organização), ssh, e o instalar.sh ao lado deste script.
#
# Variáveis só de teste (padrão: o comando real): GH_CMD, SSH_CMD, TCP_CMD, INSTALAR_SH, SSH_CONFIG_FILE.
set -euo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_cmd="${GH_CMD:-gh}"
ssh_cmd="${SSH_CMD:-ssh}"
tcp_cmd="${TCP_CMD:-tcp_ssh}"
instalar="${INSTALAR_SH:-$aqui/instalar.sh}"

uso() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
erro() { printf 'registrar.sh: %s\n' "$*" >&2; exit "${2:-2}"; }
quieto=0
passo() { if [ "$quieto" -eq 0 ]; then printf '==> %s\n' "$*"; fi; }

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
    --quieto) quieto=1; shift ;;
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
  # Nomes internos com prefixo para não esconder a variável do chamador (o printf -v grava nela).
  local _dest="$1" _txt="$2" _pad="${3:-}" _lido
  if [ -n "$_pad" ]; then printf '%s [%s]: ' "$_txt" "$_pad"; else printf '%s: ' "$_txt"; fi
  IFS= read -r _lido || fim_da_entrada
  [ -n "$_lido" ] || _lido="$_pad"
  printf -v "$_dest" '%s' "$_lido"
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

valida_vps() { # <usuário@host[:porta]> ou um nome simples (host ou Host do ~/.ssh/config)
  if [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then return 0; fi
  if ! [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?$ ]]; then
    aviso "VPS inválida: use usuário@host, usuário@host:porta ou o nome de um Host do ~/.ssh/config."; return 1
  fi
  if [[ "$1" == *:* ]] && { [ "${1##*:}" -lt 1 ] || [ "${1##*:}" -gt 65535 ]; }; then
    aviso "porta fora do intervalo 1-65535."; return 1
  fi
}

valida_host() { # só o IP ou nome do servidor (ou um Host do ~/.ssh/config)
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] && return 0
  aviso "digite só o IP ou o nome do servidor, sem usuário nem porta (eles vêm depois), ou o nome de um Host do ~/.ssh/config."
  return 1
}

valida_porta() {
  if [[ "$1" =~ ^[0-9]{1,5}$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then return 0; fi
  aviso "a porta deve ser um número de 1 a 65535."; return 1
}

valida_usuario() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] && return 0
  aviso "usuário inválido: use letras, números, _ e -."; return 1
}

# Procura algo que responda como SSH (banner "SSH-") em <host> <porta>, sem autenticar.
tcp_ssh() {
  local -a limite=()
  if command -v timeout > /dev/null 2>&1; then limite=(timeout 8); fi
  "${limite[@]}" bash -c 'exec 3<> "/dev/tcp/$1/$2" || exit 1; IFS= read -r -t 5 banner <&3 || true; case "${banner:-}" in SSH-*) exit 0 ;; esac; exit 1' _ "$1" "$2" 2> /dev/null
}

# O que o ssh -G (que não conecta) resolve para <nome>: imprime usuário@hostname:porta.
resolver_ssh() {
  local saida h p u
  saida="$("$ssh_cmd" -G "$1" 2> /dev/null < /dev/null)" || return 1
  h="$(awk '$1 == "hostname" { print $2; exit }' <<< "$saida")"
  p="$(awk '$1 == "port" { print $2; exit }' <<< "$saida")"
  u="$(awk '$1 == "user" { print $2; exit }' <<< "$saida")"
  if [ -z "$h" ]; then return 1; fi
  printf '%s@%s:%s' "$u" "$h" "$p"
}

# Se <nome> é um Host do ~/.ssh/config (o ssh -G resolve outro hostname), imprime usuário@hostname:porta.
alias_do_ssh_config() {
  local r h
  r="$(resolver_ssh "$1")" || return 1
  h="${r#*@}"; h="${h%:*}"
  if [ "${h,,}" = "${1,,}" ]; then return 1; fi
  printf '%s' "$r"
}

# Hosts concretos do ~/.ssh/config, um por linha, sem repetição: sem curingas (*, ?, !) e sem
# comentários. Só lê o arquivo principal; Include não é seguido.
hosts_do_ssh_config() {
  local arquivo="${SSH_CONFIG_FILE:-$HOME/.ssh/config}" h
  if [ ! -r "$arquivo" ]; then return 0; fi
  while IFS= read -r h; do
    if [[ "$h" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then printf '%s\n' "$h"; fi
  done < <(awk 'tolower($1) == "host" {
    for (i = 2; i <= NF; i++) {
      if ($i ~ /^#/) break
      if ($i ~ /[*?!]/) continue
      if (!($i in visto)) { visto[$i] = 1; print $i }
    }
  }' "$arquivo")
}

# Lista os Hosts salvos e pergunta qual usar. Define $vps (o alias) e limpa $chave.
escolher_host_salvo() { # <hosts…>
  local -a hosts=("$@")
  local i n descricao
  printf 'Hosts do seu ~/.ssh/config:\n'
  for i in "${!hosts[@]}"; do
    descricao="$(resolver_ssh "${hosts[$i]}")" || descricao="sem detalhes"
    printf '  %d) %s  (%s)\n' "$((i + 1))" "${hosts[$i]}" "$descricao"
  done
  while :; do
    pergunta n "Escolha um número (1-${#hosts[@]})"
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#hosts[@]}" ]; then
      vps="${hosts[$((n - 1))]}"; chave=""; return 0
    fi
    aviso "escolha um número de 1 a ${#hosts[@]}."
  done
}

# Pergunta o servidor (host, porta), verifica o SSH, e só então usuário e chave. Define $vps e $chave.
pedir_servidor() {
  local entrada porta usuario resolvido modo
  local -a salvos=()
  mapfile -t salvos < <(hosts_do_ssh_config)
  if [ "${#salvos[@]}" -gt 0 ]; then
    printf 'Como conectar na VPS?\n  1) usar um Host salvo no seu ~/.ssh/config\n  2) informar o IP ou nome do servidor\n'
    while :; do
      pergunta modo "Escolha" 1
      case "$modo" in
        1) escolher_host_salvo "${salvos[@]}"; return 0 ;;
        2) break ;;
        *) aviso "Responda 1 ou 2." ;;
      esac
    done
  fi
  while :; do
    pergunta entrada "Servidor: IP ou nome do host (ou um Host do seu ~/.ssh/config)"
    if ! valida_host "$entrada"; then continue; fi
    if resolvido="$(alias_do_ssh_config "$entrada")"; then
      printf '  Achei "%s" no ~/.ssh/config: %s. Usuário, porta e chave vêm de lá.\n' "$entrada" "$resolvido"
      vps="$entrada"; chave=""; return 0
    fi
    while :; do
      pergunta porta "Porta do SSH" 22
      if valida_porta "$porta"; then break; fi
    done
    printf 'Procurando um servidor SSH em %s:%s...\n' "$entrada" "$porta"
    if ! "$tcp_cmd" "$entrada" "$porta"; then
      aviso "nada respondeu como SSH em $entrada:$porta. Confira o IP, a porta e se a VPS está ligada."
      continue
    fi
    printf '  ok\n'
    while :; do
      pergunta usuario "Usuário do SSH" root
      if valida_usuario "$usuario"; then break; fi
    done
    while :; do
      pergunta chave "Chave privada do SSH (Enter para a padrão ou o ssh-agent)"
      case "$chave" in \~/*) chave="$HOME/${chave#\~/}" ;; esac
      if [ -z "$chave" ] || valida_chave "$chave"; then break; fi
      chave=""
    done
    vps="$usuario@$entrada"
    if [ "$porta" != 22 ]; then vps="$vps:$porta"; fi
    return 0
  done
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

# Monta, no array $base do chamador, os argumentos comuns às chamadas ao próprio script (nunca contêm o token).
montar_base() {
  local v
  base=(--vps "$vps" --nome "$nome")
  [ -z "$chave" ] || base+=(--chave "$chave")
  [ -z "$rotulos" ] || base+=(--rotulos "$rotulos")
  [ -z "$nome_github" ] || base+=(--nome-github "$nome_github")
  [ "$sem_docker" -eq 0 ] || base+=(--sem-docker)
  for v in "${extras[@]}"; do base+=(--var "$v"); done
}

assistente() {
  local mem="" cpu="" rot="" self="${BASH_SOURCE[0]}" alvo_texto padrao_nome resposta v
  local saida reserva=1024 minimo=2048
  local -a novos=()
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
    if [ -z "$vps" ]; then pedir_servidor; fi
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

  montar_base

  # 5. Painel de decisão (somente leitura): sistema, Docker, instâncias, estado desta instância, avisos e
  # veredito. Leva a URL do alvo para apontar divergências. Se não couber, para antes de gerar qualquer token.
  # Se o motivo incluir memória, oferece ajustar a reserva e o mínimo e reavaliar. A saída é capturada em
  # variável (nada é gravado em disco).
  while :; do
    printf '\nPainel da VPS (somente leitura, não cria nada):\n\n'
    if saida="$(bash "$self" "${base[@]}" "${alvo[@]}" --so-checar --quieto < /dev/null 2>&1)"; then
      printf '%s\n' "$saida"; break
    fi
    printf '%s\n' "$saida"
    if ! grep -q '^VEREDITO: não cabe:.*memória' <<< "$saida"; then
      erro "o veredito é \"não cabe\" (ou o painel falhou); nada foi instalado." 1
    fi
    printf '\nO runner não cabe por falta de memória. Saídas possíveis:\n'
    printf '  - liberar memória na VPS (o painel mostra quanto falta) ou usar uma VPS maior;\n'
    printf '  - reduzir a reserva do resto da VPS (RESERVA_MB) e/ou o mínimo do runner (MEM_MIN_MB): passa a\n'
    printf '    caber, mas sobra menos folga para os outros serviços crescerem. O limite do runner continua\n'
    printf '    valendo: um job que estourar a memória derruba só o runner, desde que sobre folga no resto da VPS;\n'
    printf '  - manter os workflows pesados nos runners do GitHub.\n\n'
    if ! sim_nao "Ajustar a reserva e o mínimo de memória e avaliar de novo?" n; then
      erro "o veredito é \"não cabe\"; nada foi instalado." 1
    fi
    while :; do
      pergunta resposta "Reserva de memória para o resto da VPS em MB" "$reserva"
      if [[ "$resposta" =~ ^[0-9]+$ ]] && [ "$resposta" -gt 0 ]; then reserva="$resposta"; break; fi
      aviso "use um número inteiro maior que zero."
    done
    while :; do
      pergunta resposta "Memória mínima para o runner em MB" "$minimo"
      if [[ "$resposta" =~ ^[0-9]+$ ]] && [ "$resposta" -gt 0 ]; then minimo="$resposta"; break; fi
      aviso "use um número inteiro maior que zero."
    done
    if [ "$minimo" -lt 1024 ]; then aviso "mínimo muito baixo: jobs com Docker podem ser mortos por falta de memória."; fi
    novos=()
    for v in "${extras[@]}"; do
      case "$v" in RESERVA_MB=* | MEM_MIN_MB=*) ;; *) novos+=("$v") ;; esac
    done
    extras=("${novos[@]}" "RESERVA_MB=$reserva" "MEM_MIN_MB=$minimo")
    montar_base
  done

  # 6. Resumo e confirmação.
  printf '\nResumo:\n  VPS:        %s\n  Alvo:       %s\n  Instância:  %s (usuário runner-%s na VPS)\n' "$vps" "$alvo_texto" "$nome" "$nome"
  printf '  Docker rootless: %s\n' "$([ "$sem_docker" -eq 0 ] && echo sim || echo não)"
  if [ "${#extras[@]}" -gt 0 ]; then printf '  Ajustes:    %s\n' "${extras[*]}"; fi
  if ! sim_nao "Instalar agora?" n; then
    printf 'Nada foi instalado.\n'; exit 0
  fi

  # 7. Instala (o token é gerado aqui, pelo gh) e mostra o estado.
  if ! bash "$self" "${base[@]}" "${alvo[@]}" < /dev/null; then
    erro "a instalação falhou (veja as mensagens acima)." 1
  fi
  printf '\nEstado da instância:\n'
  bash "$self" "${base[@]}" --status --quieto < /dev/null || aviso "não consegui ler o estado agora; rode --status depois."
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
