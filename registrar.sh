#!/usr/bin/env bash
# registrar.sh — instala, confere, mostra ou remove um runner numa VPS, a partir da sua máquina.
#
# Gera o token de registro pela API do GitHub (gh api), monta as variáveis do instalar.sh e envia
# tudo pelo SSH. O token vai pelo fluxo de entrada do SSH, junto com o script: nunca passa pela
# linha de comando (ps), pelo histórico do shell nem por arquivo.
#
# Uso:
#   registrar.sh --vps root@<vps>[:porta] | <alias do ~/.ssh/config> (--repo <dono>/<repo> | --org <org>) --nome <nome> [opções]
#   registrar.sh --vps … [--nome <nome>] --so-checar      só o diagnóstico (sem token); sem --nome, só o servidor
#   registrar.sh --vps … --nome <nome> --status           estado da instância (sem token)
#   registrar.sh --vps … --listar                         nomes das instâncias da VPS (sem token)
#   registrar.sh --vps … --nome <nome> --config           configuração gravada da instância (sem token)
#   registrar.sh --vps … --nome <nome> --sem-token --var CHAVE=valor   altera a configuração (sem token)
#   registrar.sh --vps … (--repo|--org) --nome <nome> --remover   desfaz a instância (token de remoção)
#   registrar.sh --vps … --nome <nome> --sem-token        reinstala/atualiza sem registrar de novo
#   registrar.sh --local (--repo <dono>/<repo> | --org <org>) --nome <nome> [opções]
#                                                         instala nesta própria máquina (Linux), sem SSH
#   registrar.sh (--vps … | --local) --repos <dono>/<a>,<dono>/<b> [opções]
#                                                         uma instância por repositório, numa passada;
#                                                         o nome vem do repositório e a memória é dividida
#   registrar.sh --interativo                             assistente: pergunta e valida; sem argumentos
#                                                         num terminal, é o que acontece
#
# Opções:
#   --chave <arquivo>        chave privada do SSH (-i)
#   --local                  em vez de --vps: roda o instalador nesta máquina (precisa de Linux e de root
#                            ou sudo, só para o instalador; o runner continua sem sudo)
#   --repos a/x,b/y          vários repositórios de uma vez (só instalar; não combina com --repo, --org,
#                            --nome, --nome-github, --status, --so-checar, --remover nem --mostrar)
#   --rotulos a,b            rótulos do runner (padrão: o nome)
#   --nome-github <nome>     nome do runner no GitHub, se diferente de --nome
#   --sem-docker             DOCKER_ROOTLESS=0
#   --var CHAVE=valor        qualquer variável do instalar.sh (repetível): RESERVA_MB, MEM_MIN_MB,
#                            DISCO_MIN_GB, MEMORY_MAX_MB, CPU_QUOTA, HOSTS_EXTRAS, PACOTES_EXTRAS,
#                            EXTRAS_SH, EXTRAS_SHA256, ENV_EXTRAS, RUNNER_VERSAO, RUNNER_SHA256
#   --mostrar                imprime o que seria enviado (token redigido) e não conecta
#   --perfil <arquivo>       lê opções de um arquivo chave=valor (veja exemplos/perfil-nativo.perfil); a linha
#                            de comando vence o perfil; token nunca vai no arquivo
#   --interativo             assistente para instalar (argumentos já passados pulam as perguntas)
#   --quieto                 não imprime as linhas de andamento (==>); só o que o instalador responde
#   -h, --help
#
# Pré-requisitos: gh autenticado (gh auth status) com acesso de administrador ao repositório
# (ou à organização), ssh, e o instalar.sh ao lado deste script.
#
# Variáveis só de teste (padrão: o comando real): GH_CMD, SSH_CMD, TCP_CMD, INSTALAR_SH, SSH_CONFIG_FILE,
# BASH_LOCAL_CMD, SUDO_CMD, UNAME_CMD, UID_ATUAL.
set -euo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_cmd="${GH_CMD:-gh}"
ssh_cmd="${SSH_CMD:-ssh}"
tcp_cmd="${TCP_CMD:-tcp_ssh}"
instalar="${INSTALAR_SH:-$aqui/instalar.sh}"
bash_local="${BASH_LOCAL_CMD:-bash}"
sudo_cmd="${SUDO_CMD:-sudo}"
uname_cmd="${UNAME_CMD:-uname}"
uid_atual="${UID_ATUAL:-$EUID}"
self="${BASH_SOURCE[0]}"

uso() { sed -n '2,/^set -euo/{/^set -euo/!p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
erro() { printf 'registrar.sh: %s\n' "$*" >&2; exit "${2:-2}"; }
quieto=0
passo() { if [ "$quieto" -eq 0 ]; then printf '==> %s\n' "$*"; fi; }

vps=""; chave=""; repo=""; org=""; nome=""; nome_github=""; rotulos=""
modo="instalar"; sem_docker=0; mostrar=0; interativo=0; local_=0; repos=""
n_args=$#
declare -a extras=()

# ---------- perfil ----------
# --perfil <arquivo>: linhas chave=valor que viram argumentos (a chave é o nome da opção sem "--"). O arquivo
# nunca é executado nem expandido, não aceita token e perde para a linha de comando. As opções de uma
# flag só (local, sem-docker) valem com o valor 1; var= pode repetir.
perfil_para_args() { # <arquivo>; imprime um argumento por linha
  local arq="$1" linha chave_p valor_p
  [ -r "$arq" ] || erro "não consegui ler o perfil: $arq"
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    [[ "$linha" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$linha" =~ ^[[:space:]]*([a-z-]+)=(.*)$ ]] || erro "perfil $arq: linha sem chave=valor: use chave=valor, uma por linha"
    chave_p="${BASH_REMATCH[1]}"; valor_p="${BASH_REMATCH[2]}"
    case "$chave_p" in
      token | runner-token) erro "perfil $arq: o token não vai no perfil; o registrar.sh o gera pelo gh" ;;
      local | sem-docker)
        [ "$valor_p" = 1 ] || erro "perfil $arq: $chave_p só aceita o valor 1 (para desligar, tire a linha)"
        printf '%s\n' "--$chave_p" ;;
      vps | chave | repo | org | repos | nome | nome-github | rotulos)
        if [ "$chave_p" = chave ]; then case "$valor_p" in \~/*) valor_p="$HOME/${valor_p#\~/}" ;; esac; fi
        printf '%s\n%s\n' "--$chave_p" "$valor_p" ;;
      var)
        case "$valor_p" in RUNNER_TOKEN=*) erro "perfil $arq: o token não vai no perfil; o registrar.sh o gera pelo gh" ;; esac
        printf '%s\n%s\n' "--var" "$valor_p" ;;
      *) erro "perfil $arq: chave desconhecida \"$chave_p\" (use vps, chave, local, repo, org, repos, nome, nome-github, rotulos, sem-docker ou var)" ;;
    esac
  done < "$arq"
}

declare -a args_perfil=() args_linha=()
while [ $# -gt 0 ]; do
  if [ "$1" = --perfil ]; then
    [ -n "${2:-}" ] || erro "--perfil espera um arquivo"
    _lidos="$(perfil_para_args "$2")" || exit 2   # (o erro sai de dentro da substituição: repete o código aqui)
    if [ -n "$_lidos" ]; then mapfile -t _novos <<< "$_lidos"; args_perfil+=("${_novos[@]}"); fi
    shift 2
  else
    args_linha+=("$1"); shift
  fi
done
set -- "${args_perfil[@]}" "${args_linha[@]}"

while [ $# -gt 0 ]; do
  case "$1" in
    --vps) vps="${2:-}"; shift 2 ;;
    --chave) chave="${2:-}"; shift 2 ;;
    --local) local_=1; shift ;;
    --repos) repos="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --org) org="${2:-}"; shift 2 ;;
    --nome) nome="${2:-}"; shift 2 ;;
    --nome-github) nome_github="${2:-}"; shift 2 ;;
    --rotulos) rotulos="${2:-}"; shift 2 ;;
    --sem-docker) sem_docker=1; shift ;;
    --var) extras+=("${2:-}"); shift 2 ;;
    --so-checar) modo="so-checar"; shift ;;
    --listar) modo="listar"; shift ;;
    --config) modo="config"; shift ;;
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
    pergunta entrada "Servidor: IP ou nome do host (ou um Host do seu ~/.ssh/config); \"local\" instala nesta máquina"
    if [ "$entrada" = local ]; then local_=1; return 0; fi
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

# --local: só Linux, e root ou sudo (o sudo é só para o instalador; o runner nunca recebe sudo).
checar_local() {
  [ "$("$uname_cmd" -s)" = Linux ] || erro "--local só funciona em Linux (o instalador usa systemd e usuários do sistema). Em outra máquina, use --vps." 1
  if [ "$uid_atual" -ne 0 ]; then
    command -v "$sudo_cmd" > /dev/null 2>&1 || erro "--local precisa de root ou de sudo (só para o instalador): rode como root ou instale o sudo." 1
  fi
}

ssh_assistente() { # <comando remoto…>; sem terminal, sem senha (BatchMode)
  if [ "$local_" -eq 1 ]; then # mesma pergunta, feita nesta máquina
    local -a pre=()
    if [ "$uid_atual" -ne 0 ]; then pre=("$sudo_cmd"); fi
    "${pre[@]}" "$bash_local" -c "$*" < /dev/null
    return
  fi
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
  if [ "$local_" -eq 1 ]; then base=(--local); else base=(--vps "$vps"); fi
  # (com "servidor" o nome fica de fora: é o painel que roda antes de a instância existir)
  if [ "${1:-}" != servidor ] && [ -n "$nome" ]; then base+=(--nome "$nome"); fi
  [ -z "$chave" ] || base+=(--chave "$chave")
  [ -z "$rotulos" ] || base+=(--rotulos "$rotulos")
  [ -z "$nome_github" ] || base+=(--nome-github "$nome_github")
  [ "$sem_docker" -eq 0 ] || base+=(--sem-docker)
  for v in "${extras[@]}"; do base+=(--var "$v"); done
}

# HH:MM-HH:MM (24 h), com início diferente do fim.
valida_janela() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && [ "${1%-*}" != "${1#*-}" ]; }
# AAAA-MM-DD válida (a data de hoje da máquina de quem administra; a VPS confere de novo com o relógio dela).
valida_validade() { # devolve 0 válida e futura; 1 formato/data inválidos; 2 já passou
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [ "$(date -d "$1" +%F 2> /dev/null || true)" = "$1" ] || return 1
  if [[ "$(date +%F)" > "$1" ]]; then return 2; fi
  return 0
}
# pedir_janela <variável> <padrão> <permite '-' para remover: 0|1>
pedir_janela() {
  local _alvo_pj="$1" _pad_pj="$2" _rm_pj="$3" _v_pj
  local _txt_pj="Janela de horário (HH:MM-HH:MM, horário da VPS; vazio = sempre ligado)"
  if [ "$_rm_pj" -eq 1 ]; then _txt_pj="Janela de horário (HH:MM-HH:MM, horário da VPS; - remove)"; fi
  while :; do
    pergunta _v_pj "$_txt_pj" "$_pad_pj"
    if [ -z "$_v_pj" ] || { [ "$_rm_pj" -eq 1 ] && [ "$_v_pj" = - ]; } || valida_janela "$_v_pj"; then break; fi
    aviso "use HH:MM-HH:MM (24 h), com início diferente do fim, ex.: 22:00-06:00."
  done
  if [ "$_v_pj" = - ]; then _v_pj=""; fi
  printf -v "$_alvo_pj" '%s' "$_v_pj"
}
# pedir_validade <variável> <padrão> <permite '-' para remover: 0|1>
pedir_validade() {
  local _alvo_pv="$1" _pad_pv="$2" _rm_pv="$3" _v_pv _rc_pv
  local _txt_pv="Validade (AAAA-MM-DD, o runner desliga no fim desse dia; vazio = sem validade)"
  if [ "$_rm_pv" -eq 1 ]; then _txt_pv="Validade (AAAA-MM-DD; - remove)"; fi
  while :; do
    pergunta _v_pv "$_txt_pv" "$_pad_pv"
    if [ -z "$_v_pv" ] || { [ "$_rm_pv" -eq 1 ] && [ "$_v_pv" = - ]; }; then break; fi
    _rc_pv=0; valida_validade "$_v_pv" || _rc_pv=$?
    if [ "$_rc_pv" -eq 0 ]; then break; fi
    if [ "$_rc_pv" -eq 2 ]; then aviso "essa data já passou (hoje é $(date +%F)): informe uma data futura."
    else aviso "use uma data válida AAAA-MM-DD, ex.: 2026-12-31."; fi
  done
  if [ "$_v_pv" = - ]; then _v_pv=""; fi
  printf -v "$_alvo_pv" '%s' "$_v_pv"
}

# Valor de uma chave num texto CHAVE=valor (uma por linha); vazio se não houver.
valor_de() { # <chave> <texto>
  local linha
  while IFS= read -r linha; do
    if [ "${linha%%=*}" = "$1" ]; then printf '%s' "${linha#*=}"; return 0; fi
  done <<< "$2"
  return 0
}

# Define $nome a partir de uma lista de instâncias (uma por linha): com uma só, usa ela; com várias, pergunta o número.
escolher_instancia() { # <lista>
  local -a nomes=()
  local i _esc
  mapfile -t nomes <<< "$1"
  if [ "${#nomes[@]}" -eq 1 ]; then nome="${nomes[0]}"; printf 'Instância: %s\n' "$nome"; return 0; fi
  while :; do
    printf '\nInstâncias nesta VPS:\n'
    for i in "${!nomes[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${nomes[$i]}"; done
    pergunta _esc "Escolha o número"
    if [[ "$_esc" =~ ^[0-9]+$ ]] && [ "$_esc" -ge 1 ] && [ "$_esc" -le "${#nomes[@]}" ]; then
      nome="${nomes[$((_esc - 1))]}"; return 0
    fi
    aviso "responda um número de 1 a ${#nomes[@]}."
  done
}

# Mostra a configuração gravada da instância $nome, pergunta o que mudar (só o que não precisa de token) e
# reaplica com --sem-token. Usa as variáveis do assistente (base, self).
configurar_instancia() {
  local cfg linha mem_atual cpu_atual mem_nova cpu_nova v janela_atual validade_atual janela_nova validade_nova
  local -a mudancas=() vars=() args=()
  if ! cfg="$(bash "$self" "${base[@]}" --nome "$nome" --config --quieto < /dev/null 2>&1)"; then
    printf '%s\n' "$cfg" >&2; erro "não consegui ler a configuração de $nome." 1
  fi
  printf '\nConfiguração gravada de %s:\n' "$nome"
  while IFS= read -r linha; do printf '  %s\n' "$linha"; done <<< "$cfg"
  printf '\nEnter mantém o valor atual.\n'
  mem_atual="$(valor_de MEMORY_MAX_MB "$cfg")"; cpu_atual="$(valor_de CPU_QUOTA "$cfg")"
  while :; do
    pergunta mem_nova "Memória máxima do runner em MB" "$mem_atual"
    if [ -z "$mem_nova" ] || { [[ "$mem_nova" =~ ^[0-9]+$ ]] && [ "$mem_nova" -gt 0 ]; }; then break; fi
    aviso "use um número inteiro maior que zero (MB)."
  done
  while :; do
    pergunta cpu_nova "Cota de CPU em % de um núcleo" "$cpu_atual"
    if [ -z "$cpu_nova" ] || { [[ "$cpu_nova" =~ ^[0-9]+%?$ ]] && [ "${cpu_nova%\%}" -gt 0 ]; }; then break; fi
    aviso "use um número inteiro maior que zero, ex.: 200."
  done
  cpu_nova="${cpu_nova%\%}"
  janela_atual="$(valor_de JANELA "$cfg")"; validade_atual="$(valor_de VALIDADE "$cfg")"
  pedir_janela janela_nova "$janela_atual" 1
  pedir_validade validade_nova "$validade_atual" 1
  if [ -n "$mem_nova" ] && [ "$mem_nova" != "$mem_atual" ]; then
    vars+=("MEMORY_MAX_MB=$mem_nova"); mudancas+=("MEMORY_MAX_MB: ${mem_atual:-(calculado)} -> $mem_nova")
  fi
  if [ -n "$cpu_nova" ] && [ "$cpu_nova" != "$cpu_atual" ]; then
    vars+=("CPU_QUOTA=$cpu_nova"); mudancas+=("CPU_QUOTA: ${cpu_atual:-(calculado)} -> $cpu_nova")
  fi
  if [ "$janela_nova" != "$janela_atual" ]; then
    vars+=("JANELA=$janela_nova"); mudancas+=("JANELA: ${janela_atual:-(sempre ligado)} -> ${janela_nova:-(sempre ligado)}")
  fi
  if [ "$validade_nova" != "$validade_atual" ]; then
    vars+=("VALIDADE=$validade_nova"); mudancas+=("VALIDADE: ${validade_atual:-(sem validade)} -> ${validade_nova:-(sem validade)}")
  fi
  if [ "${#vars[@]}" -eq 0 ]; then printf '\nNada a alterar.\n'; return 0; fi
  if [ -n "$mem_nova" ] && [ "$mem_nova" -lt 1024 ]; then
    aviso "memória abaixo de 1024 MB: jobs com Docker podem ser mortos por falta de memória."
  fi
  printf '\nMudanças em %s:\n' "$nome"
  for linha in "${mudancas[@]}"; do printf '  %s\n' "$linha"; done
  if ! sim_nao "Aplicar agora? (reaplica a instância sem registrar de novo; o diagnóstico roda de novo e o serviço só reinicia se a unidade mudar)" n; then
    printf 'Nada foi alterado.\n'; return 0
  fi
  for v in "${vars[@]}"; do args+=(--var "$v"); done
  if ! bash "$self" "${base[@]}" --nome "$nome" --sem-token "${args[@]}" < /dev/null; then
    erro "a reaplicação falhou (veja as mensagens acima)." 1
  fi
  printf '\nEstado da instância:\n'
  bash "$self" "${base[@]}" --nome "$nome" --status --quieto < /dev/null || aviso "não consegui ler o estado agora; rode --status depois."
  printf '\nPara repetir sem o assistente:\n  ./registrar.sh'
  for linha in "${base[@]}" --nome "$nome" --sem-token "${args[@]}"; do printf ' %q' "$linha"; done
  printf '\n'
}

# Remove a instância $nome. O repositório ou a organização vêm da URL gravada na configuração; só gera o token de
# remoção (e só chama a VPS) depois de confirmar e de checar que o gh é administrador.
remover_do_menu() {
  local cfg url
  if ! cfg="$(bash "$self" "${base[@]}" --nome "$nome" --config --quieto < /dev/null 2>&1)"; then
    printf '%s\n' "$cfg" >&2; erro "não consegui ler a configuração de $nome." 1
  fi
  url="$(valor_de RUNNER_URL "$cfg")"
  repo=""; org=""
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)$ ]]; then repo="${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^https://github\.com/([A-Za-z0-9._-]+)$ ]]; then org="${BASH_REMATCH[1]}"
  else
    erro "não achei o repositório nem a organização de $nome na configuração (RUNNER_URL=${url:-vazio}); use ./registrar.sh --vps … --nome $nome --repo <dono>/<repo> --remover." 1
  fi
  printf '\nAlvo da instância: %s\n' "${repo:-$org}"
  if ! sim_nao "Remover a instância $nome? Apaga o runner, o usuário runner-$nome e os dados dela na VPS." n; then
    printf 'Nada foi removido.\n'; return 0
  fi
  valida_alvo || erro "sem permissão para gerar o token de remoção; nada foi removido." 1
  if [ -n "$repo" ]; then alvo=(--repo "$repo"); else alvo=(--org "$org"); fi
  if ! bash "$self" "${base[@]}" --nome "$nome" "${alvo[@]}" --remover < /dev/null; then
    erro "a remoção falhou (veja as mensagens acima)." 1
  fi
  printf '\nInstância %s removida.\n' "$nome"
}

# VPS que já tem instâncias: pergunta o que fazer. Instalar devolve o controle ao fluxo normal; as outras opções
# fazem o que foi pedido e terminam o assistente.
menu_instancias() { # <lista>
  local lista="$1" escolha nomes_txt
  nomes_txt="$(paste -sd, - <<< "$lista" | sed 's/,/, /g')"
  printf '\nEsta VPS já tem instâncias: %s.\nO que você quer fazer?\n' "$nomes_txt"
  printf '  1) Instalar uma instância nova\n  2) Ver o estado de uma instância\n'
  printf '  3) Ver ou alterar a configuração de uma instância\n  4) Remover uma instância\n'
  while :; do
    pergunta escolha "Escolha (1-4)" 1
    case "$escolha" in 1 | 2 | 3 | 4) break ;; *) aviso "responda 1, 2, 3 ou 4." ;; esac
  done
  if [ "$escolha" = 1 ]; then return 0; fi
  escolher_instancia "$lista"
  case "$escolha" in
    2) if ! bash "$self" "${base[@]}" --nome "$nome" --status --quieto < /dev/null; then erro "não consegui ler o estado de $nome." 1; fi ;;
    3) configurar_instancia ;;
    4) remover_do_menu ;;
  esac
  exit 0
}

# Runner self-hosted em repositório público: qualquer pessoa pode abrir um PR de um fork, e os workflows de PR
# rodariam no servidor. Só avisa e pede confirmação; não bloqueia. Devolve 0 para seguir e 1 para parar.
# Falha ao consultar a visibilidade não impede: avisa e segue. Organizações não são consultadas (a visibilidade
# vale por repositório e, por padrão, o grupo de runners da organização não atende repositórios públicos).
confirmar_visibilidade() { # usa $repo
  local privado
  if ! privado="$("$gh_cmd" api "repos/$repo" --jq .private 2> /dev/null < /dev/null)"; then privado=""; fi
  case "$privado" in
    true) return 0 ;;
    false)
      printf '\nAtenção: %s é público.\n' "$repo"
      printf '  Qualquer pessoa pode abrir um pull request a partir de um fork, e os workflows de pull request\n'
      printf '  rodariam neste servidor, com acesso à rede e aos recursos da VPS. O GitHub recomenda usar runners\n'
      printf '  self-hosted só com repositórios privados. Se mesmo assim for usar, confira em Settings > Actions >\n'
      printf '  General a aprovação de workflows de forks e evite dar ao runner qualquer segredo ou acesso sensível.\n\n'
      sim_nao "Continuar mesmo assim?" n ;;
    *)
      aviso "não consegui verificar se $repo é público ou privado; confira antes de usar o runner (runner self-hosted em repositório público é arriscado)."
      return 0 ;;
  esac
}

# Avalia o painel de decisão (somente leitura) em duas etapas e devolve só quando cabe:
#   servidor  - logo depois de a VPS conectar, antes de perguntar o repositório: sistema, Docker, instâncias
#               e recursos (não leva nome nem URL). Se não couber, nada mais é perguntado.
#   instancia - depois do repositório, do nome e das opções: acrescenta a situação desta instância e os avisos
#               que dependem da URL; mostra só a parte nova (da seção da instância em diante).
# Se o motivo incluir memória, oferece ajustar a reserva e o mínimo e reavaliar. A saída é capturada em variável
# (nada é gravado em disco). Usa as variáveis do assistente (base, alvo, extras, reserva, minimo, saida, …).
# Painel que não deu "VEREDITO: não cabe" mas também não deu "cabe": o painel falhou (permissão, conexão…).
# Diz isso com clareza, para não parecer que a VPS é pequena demais. <saída do painel>
falha_do_painel() {
  local linha
  linha="$(grep -m1 '^ERRO:' <<< "$1")" || linha="$(grep -v '^[[:space:]]*$' <<< "$1" | tail -n 1)"
  printf '\nO painel falhou antes de dar o veredito (isso não quer dizer que a VPS seja pequena): %s\n' "${linha:-sem mensagem}" >&2
  case "$linha" in
    *root*) printf 'Conecte com o usuário root (o instalador cria usuários e serviços do sistema).\n' >&2 ;;
  esac
  erro "o painel falhou; nada foi instalado." 1
}

avaliar_painel() {
  local etapa="$1" parte
  local -a args=()
  while :; do
    montar_base "$etapa"
    if [ "$etapa" = servidor ]; then
      printf '\nPainel da VPS (somente leitura, não cria nada):\n\n'; args=("${base[@]}")
    else
      printf '\nPainel desta instância (somente leitura, não cria nada):\n\n'; args=("${base[@]}" "${alvo[@]}")
    fi
    saida_ok=0
    if saida="$(bash "$self" "${args[@]}" --so-checar --quieto < /dev/null 2>&1)"; then saida_ok=1; fi
    parte="$saida"
    if [ "$etapa" != servidor ]; then
      parte="$(sed -n '/^== Esta instância/,$p' <<< "$saida")"
      [ -n "$parte" ] || parte="$saida"
    fi
    printf '%s\n' "$parte"
    if [ "$saida_ok" -eq 1 ]; then break; fi
    if ! grep -q '^VEREDITO: não cabe' <<< "$saida"; then falha_do_painel "$saida"; fi
    if ! grep -q '^VEREDITO: não cabe:.*memória' <<< "$saida"; then
      erro "o veredito é \"não cabe\"; nada foi instalado." 1
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
  done
}

assistente() {
  local mem="" cpu="" rot="" self="${BASH_SOURCE[0]}" alvo_texto padrao_nome resposta v
  local saida saida_ok reserva=1024 minimo=2048 lista janela="" validade=""
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
  if [ "$local_" -eq 1 ]; then
    [ -z "$vps" ] || erro "--local e --vps não combinam: --local instala nesta máquina, --vps em outra"
    [ -z "$chave" ] || erro "--local não usa SSH, então não aceita --chave"
  fi
  while :; do
    if [ "$local_" -eq 0 ] && [ -z "$vps" ]; then pedir_servidor; fi
    if [ "$local_" -eq 1 ]; then
      checar_local
      printf 'Instalando nesta máquina (Linux); o sudo, se preciso, é só para o instalador.\n'
      break
    fi
    define_destino
    printf 'Testando a conexão com %s...\n' "$vps"
    if ssh_assistente true > /dev/null 2>&1; then printf '  ok\n'; break; fi
    aviso "não consegui conectar em $vps. Confira host, porta e chave. O assistente usa BatchMode: chave com senha precisa estar no ssh-agent."
    vps=""; chave=""
  done

  # 1a. VPS que já tem instâncias: menu (instalar, ver o estado, ver/alterar a configuração, remover). Quem passou
  # --nome, --repo ou --org já disse que quer instalar: segue direto.
  if [ -z "$nome" ] && [ -z "$repo" ] && [ -z "$org" ]; then
    montar_base servidor
    lista="$(bash "$self" "${base[@]}" --listar --quieto < /dev/null 2> /dev/null)" || lista=""
    if [ -n "$lista" ]; then menu_instancias "$lista"; fi
  fi

  # 1b. Painel do servidor: se a VPS não cabe o runner, para aqui, antes de perguntar o repositório.
  avaliar_painel servidor

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
  if [ -n "$repo" ] && ! confirmar_visibilidade; then
    erro "repositório público: nada foi instalado." 1
  fi

  # 3. Nome da instância (sugestão derivada do alvo); avisa se já existe na VPS.
  padrao_nome="${repo#*/}"; [ -n "$repo" ] || padrao_nome="$org"
  padrao_nome="${padrao_nome,,}"; padrao_nome="${padrao_nome//[^a-z0-9-]/-}"
  while :; do
    if [ -z "$nome" ]; then
      pergunta nome "Nome da instância (vira o usuário runner-<nome> na VPS)" "$padrao_nome"
      if ! valida_nome "$nome"; then nome=""; continue; fi
    fi
    if ssh_assistente "test -e /etc/runner-vps/$nome.conf" > /dev/null 2>&1; then
      if sim_nao "Já existe uma instância \"$nome\" nesse servidor. Reaplicar por cima (é idempotente)?" n; then break; fi
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
    pedir_janela janela "" 0
    pedir_validade validade "" 0
    [ -z "$mem" ] || extras+=("MEMORY_MAX_MB=$mem")
    [ -z "$cpu" ] || extras+=("CPU_QUOTA=${cpu%\%}")
    [ -z "$rot" ] || rotulos="$rot"
    [ -z "$janela" ] || extras+=("JANELA=$janela")
    [ -z "$validade" ] || extras+=("VALIDADE=$validade")
    sim_nao "Instalar o Docker rootless do runner?" s || sem_docker=1
  fi

  # 5. Painel desta instância (somente leitura): leva a URL do alvo para apontar divergências e dá o veredito
  # final, já com as opções avançadas. Se não couber, para antes de gerar qualquer token.
  avaliar_painel instancia
  montar_base

  # 6. Resumo e confirmação.
  printf '\nResumo:\n  Onde:       %s\n  Alvo:       %s\n  Instância:  %s (usuário runner-%s)\n' "$([ "$local_" -eq 1 ] && echo 'esta máquina' || echo "VPS $vps")" "$alvo_texto" "$nome" "$nome"
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
  [ "$modo" = instalar ] || erro "--interativo só serve para instalar (sem --status, --so-checar, --listar, --config, --remover ou --sem-token)"
  [ "$mostrar" -eq 0 ] || erro "--interativo não combina com --mostrar"
  assistente
  exit 0
fi

if [ "$local_" -eq 1 ]; then
  [ -z "$vps" ] || erro "--local e --vps não combinam: --local instala nesta máquina, --vps em outra"
  [ -z "$chave" ] || erro "--local não usa SSH, então não aceita --chave"
else
  [ -n "$vps" ] || erro "falta --vps root@<vps>[:porta], --local ou --interativo"
fi
# O painel do servidor (--so-checar) e a lista (--listar) dispensam o nome da instância; os demais modos exigem.
if [ -z "$repos" ] && { [ -n "$nome" ] || { [ "$modo" != so-checar ] && [ "$modo" != listar ]; }; }; then
  [ -n "$nome" ] || erro "falta --nome <nome>"
  [[ "$nome" =~ ^[a-z0-9-]+$ ]] || erro "--nome só aceita [a-z0-9-]: $nome"
fi
[ -r "$instalar" ] || erro "não achei o instalar.sh em $instalar" 1
for v in "${extras[@]}"; do
  [[ "$v" =~ ^[A-Z][A-Z0-9_]*=.*$ ]] || erro "--var espera CHAVE=valor, com a chave em maiúsculas: $v"
  [[ "$v" != RUNNER_TOKEN=* ]] || erro "não passe RUNNER_TOKEN por --var: o script gera o token"
done

# ---------- vários repositórios de uma vez ----------
# Uma instância por repositório, com o nome derivado do repositório. O painel do servidor roda uma vez,
# antes de qualquer token; a memória que o painel diz que cabe é dividida em partes iguais (múltiplos de
# 256 MB) e cada instância recebe a sua fatia por MEMORY_MAX_MB. Cada instalação é uma chamada deste mesmo
# script, com o seu próprio token; a primeira que falhar interrompe o lote.
lote() {
  local r n i total min por_instancia saida resto
  local -a itens=() nomes=() novos=() feitas=() restantes=() base=() extras_orig=()
  [ "$modo" = instalar ] || erro "--repos só serve para instalar (sem --status, --so-checar, --listar, --config, --remover ou --sem-token)"
  [ -z "$repo" ] && [ -z "$org" ] || erro "--repos não combina com --repo nem --org"
  [ -z "$nome" ] || erro "--repos não combina com --nome: o nome de cada instância vem do repositório"
  [ -z "$nome_github" ] || erro "--repos não combina com --nome-github: cada instância precisa de um nome próprio no GitHub"
  [ "$mostrar" -eq 0 ] || erro "--repos não combina com --mostrar: rode com um repositório só para ver o que seria enviado"
  case "$repos" in ,* | *, | *,,*) erro "--repos tem um item vazio: $repos" ;; esac
  IFS=, read -r -a itens <<< "$repos"
  [ "${#itens[@]}" -ge 1 ] || erro "--repos está vazio"
  for r in "${itens[@]}"; do
    [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || erro "--repos espera <dono>/<repo> separados por vírgula: $r"
    n="${r#*/}"; n="${n,,}"; n="${n//[^a-z0-9]/-}"
    while [[ "$n" == -* ]]; do n="${n#-}"; done
    while [[ "$n" == *- ]]; do n="${n%-}"; done
    [ -n "$n" ] || erro "não consegui derivar um nome para $r: rode esse repositório sozinho, com --nome"
    for i in "${nomes[@]}"; do
      [ "$i" != "$n" ] || erro "dois repositórios dariam o mesmo nome de instância ($n): rode um deles sozinho, com --nome"
    done
    nomes+=("$n")
  done

  extras_orig=("${extras[@]}")
  min=2048; por_instancia=""
  for r in "${extras[@]}"; do
    case "$r" in MEM_MIN_MB=*) min="${r#*=}" ;; MEMORY_MAX_MB=*) por_instancia="${r#*=}" ;; esac
  done
  if [ -z "$por_instancia" ]; then
    montar_base servidor
    local ok=1
    saida="$(bash "$self" "${base[@]}" --so-checar --quieto < /dev/null 2>&1)" || ok=0
    printf '%s\n' "$saida"
    if [ "$ok" -eq 0 ]; then
      if grep -q '^VEREDITO: não cabe' <<< "$saida"; then erro "o veredito é \"não cabe\"; nada foi instalado." 1; fi
      falha_do_painel "$saida"
    fi
    total="$(sed -n 's/^VEREDITO: cabe (MemoryMax=\([0-9][0-9]*\)M.*/\1/p' <<< "$saida" | head -n 1)"
    [ -n "$total" ] || erro "não consegui ler a memória disponível no painel da VPS; nada foi instalado." 1
    por_instancia=$((total / ${#itens[@]} / 256 * 256))
    if [ "$por_instancia" -lt "$min" ]; then
      erro "não cabe para ${#itens[@]} instâncias: cada uma teria ${por_instancia} MB (de ${total} MB), abaixo do mínimo de ${min} MB. Use menos repositórios, uma VPS maior ou baixe o mínimo com --var MEM_MIN_MB=<MB> (jobs com Docker pedem pelo menos 1024). Nada foi instalado." 1
    fi
    for r in "${extras[@]}"; do novos+=("$r"); done
    extras=("${novos[@]}" "MEMORY_MAX_MB=$por_instancia")
  fi

  printf '\nInstâncias a instalar (%d), com MemoryMax=%sM cada:\n' "${#itens[@]}" "$por_instancia"
  for i in "${!itens[@]}"; do printf '  %s  <-  %s\n' "${nomes[$i]}" "${itens[$i]}"; done
  printf '\n'

  restantes=("${nomes[@]}")
  for i in "${!itens[@]}"; do
    nome="${nomes[$i]}"
    montar_base
    local -a q=()
    [ "$quieto" -eq 0 ] || q=(--quieto)
    if ! bash "$self" "${base[@]}" --repo "${itens[$i]}" "${q[@]}" < /dev/null; then
      restantes=("${restantes[@]:1}")
      resto="${restantes[*]}"
      printf 'registrar.sh: a instalação falhou em %s.\n' "${itens[$i]}" >&2
      printf 'registrar.sh: instaladas: %s\n' "${feitas[*]:-nenhuma}" >&2
      printf 'registrar.sh: não tentadas: %s\n' "${resto:-nenhuma}" >&2
      exit 1
    fi
    feitas+=("$nome"); restantes=("${restantes[@]:1}")
  done
  extras=("${extras_orig[@]}")
  printf 'Lote concluído: %s.\n' "${feitas[*]}"
}

if [ -n "$repos" ]; then lote; exit 0; fi

# ---------- execução local ----------
if [ "$local_" -eq 1 ] && [ "$mostrar" -eq 0 ]; then checar_local; fi

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
  so-checar | listar | config | status | sem-token) ;;
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
  [ -z "$nome" ] || printf 'export RUNNER_NOME=%q\n' "$nome"
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
  listar) argumento="--listar" ;;
  config) argumento="--config" ;;
  status) argumento="--status" ;;
  remover) argumento="--remover" ;;
esac

declare -a ssh_args=() cmd_exec=()
if [ "$local_" -eq 1 ]; then
  if [ "$uid_atual" -ne 0 ]; then cmd_exec+=("$sudo_cmd"); fi
  cmd_exec+=("$bash_local" -s --)
  [ -z "$argumento" ] || cmd_exec+=("$argumento")
else
  [ -z "$chave" ] || ssh_args+=(-i "$chave")
  [ -z "$porta" ] || ssh_args+=(-p "$porta")
  ssh_args+=(-o BatchMode=yes "$host" "bash -s -- $argumento")
  cmd_exec=("$ssh_cmd" "${ssh_args[@]}")
fi

if [ "$mostrar" -eq 1 ]; then
  passo "Comando: ${cmd_exec[*]}"
  passo "Entrada (depois destas linhas vai o instalar.sh):"
  montar_env 1
  exit 0
fi

if [ "$local_" -eq 1 ]; then passo "Rodando o instalar.sh nesta máquina ($modo)"; else passo "Enviando o instalar.sh para $host ($modo)"; fi
# O token entra só aqui, pelo stdin do ssh (ou do shell local): não há linha de comando nem arquivo com ele.
{ montar_env 0; cat "$instalar"; } | "${cmd_exec[@]}"
