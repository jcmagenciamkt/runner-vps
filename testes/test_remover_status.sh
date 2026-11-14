#!/usr/bin/env bash
# Testes de --status e --remover do instalar.sh (Task 3 do plano). Tudo contra a VPS falsa.
set -uo pipefail
aqui="$(cd "$(dirname "$0")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
URL=https://github.com/dono/repo
rodar() { bash "$script" "$@" > "$TMP/out" 2> "$TMP/err"; }
chamou() { grep -qF -- "$1" "$TMP/chamadas.log"; }
instalar() { RUNNER_NOME="$1" RUNNER_URL=$URL HOSTS_EXTRAS="127.0.0.1 $1.exemplo.test" RUNNER_TOKEN="$TOKEN_FALSO" rodar; }
RAIZ_T="$TMP/raiz"
H() { printf '%s' "$RAIZ_T/opt/runner-vps/$1"; }

echo "instalar.sh --status"
nova_vps
instalar exemplo
printf 'linha antiga\n2023-11-14 job=build run=7 disco=30G\n' > "$(H exemplo)/runner-vps.log"
antes="$(snapshot "$RAIZ_T")"; : > "$TMP/chamadas.log"
RUNNER_NOME=exemplo rodar --status; codigo=$?
afirmar "status: saída 0" test "$codigo" -eq 0
afirmar "status: mostra o usuário" grep -q "runner-exemplo" "$TMP/out"
afirmar "status: mostra o estado dos serviços" bash -c 'grep -q "serviço runner-vps: active" "$1" && grep -q "serviço docker: active" "$1"' _ "$TMP/out"
afirmar "status: mostra os limites" bash -c 'grep -q "MemoryMax=5120M" "$1" && grep -q "CPUQuota=300%" "$1"' _ "$TMP/out"
afirmar "status: mostra a última linha do log" grep -q "job=build run=7" "$TMP/out"
afirmar "status: não mostra linhas antigas do log" bash -c '! grep -q "linha antiga" "$1"' _ "$TMP/out"
afirmar "status: runner registrado (existência, não conteúdo)" grep -q "registro: .runner presente" "$TMP/out"
afirmar "status: não altera nada" test "$antes" = "$(snapshot "$RAIZ_T")"
afirmar "status: só consulta os serviços (is-active)" bash -c '! grep -vE "^systemctl .*is-active" "$1"' _ "$TMP/chamadas.log"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
RUNNER_NOME=inexistente rodar --status; codigo=$?
afirmar "status de instância inexistente: saída 1" test "$codigo" -eq 1

echo "instalar.sh --remover"
MEM_LIVRE_MB=16384 nova_vps
MEMORY_MAX_MB=4096 instalar exemplo
instalar outra
antes="$(snapshot "$RAIZ_T")"; : > "$TMP/chamadas.log"
RUNNER_NOME=exemplo rodar --remover; codigo=$?
afirmar "remover sem token: recusa com saída 2" test "$codigo" -eq 2
afirmar "remover sem token: nada alterado" test "$antes" = "$(snapshot "$RAIZ_T")"
afirmar "remover sem token: nenhum comando com efeito" test ! -s "$TMP/chamadas.log"

RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" rodar --remover; codigo=$?
afirmar "remover com token: saída 0" test "$codigo" -eq 0
afirmar "remover: config.sh remove chamado, sem o token nos argumentos" chamou "config.sh remove"
afirmar "remover: o token chegou ao config.sh pelo ambiente" test "$(cat "$TMP/config-token-visto")" = "$TOKEN_FALSO"
afirmar "remover: serviços parados e desabilitados" \
  bash -c 'grep -qF "disable --now runner-vps" "$1" && grep -qF "disable --now docker" "$1"' _ "$TMP/chamadas.log"
afirmar "remover: rootless desinstalado" chamou "rootless uninstall"
afirmar "remover: linger desligado" chamou "loginctl disable-linger runner-exemplo"
afirmar "remover: apaga o HOME da instância" test ! -e "$(H exemplo)"
afirmar "remover: apaga o .conf" test ! -e "$RAIZ_T/etc/runner-vps/exemplo.conf"
afirmar "remover: apaga o .slice.d da instância" test ! -e "$RAIZ_T/etc/systemd/system/user-2001.slice.d/runner-vps.conf"
afirmar "remover: apaga a linha marcada do /etc/hosts" bash -c '! grep -q "# runner-vps exemplo$" "$1/etc/hosts"' _ "$RAIZ_T"
afirmar "remover: mantém as outras linhas do /etc/hosts" bash -c 'grep -qx "127.0.0.1 localhost" "$1/etc/hosts" && grep -q "# runner-vps outra$" "$1/etc/hosts"' _ "$RAIZ_T"
afirmar "remover: apaga o usuário (sem arquivos fora do HOME)" chamou "userdel runner-exemplo"
afirmar "remover: linhas de subuid ficam" grep -q "^runner-exemplo:" "$RAIZ_T/etc/subuid"
afirmar "remover: outra instância intacta (HOME, .conf, fatia, usuário)" \
  test -d "$(H outra)/runner" -a -f "$RAIZ_T/etc/runner-vps/outra.conf" -a -f "$RAIZ_T/etc/systemd/system/user-2002.slice.d/runner-vps.conf" -a -f "$TMP/usuarios/runner-outra"
afirmar "remover: não toca na outra instância" bash -c '! grep -E "outra" "$1" | grep -qE "^(userdel|config.sh|rootless uninstall|loginctl disable)"' _ "$TMP/chamadas.log"
afirmar_sem "$TMP/chamadas.log" "$TOKEN_FALSO"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"
afirmar_sem "$RAIZ_T" "$TOKEN_FALSO"

echo "instalar.sh --remover: casos de cuidado"
# arquivo do usuário fora do HOME: o usuário fica
nova_vps
instalar exemplo
printf '#!/usr/bin/env bash\necho /var/tmp/arquivo-do-runner\n' > "$TMP/bin/arquivos-com-sobra"; chmod +x "$TMP/bin/arquivos-com-sobra"
ARQUIVOS_DO_USUARIO_CMD="$TMP/bin/arquivos-com-sobra" RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" rodar --remover; codigo=$?
afirmar "arquivo fora do HOME: saída 0" test "$codigo" -eq 0
afirmar "arquivo fora do HOME: o usuário não é apagado" bash -c '! grep -q "^userdel" "$1"' _ "$TMP/chamadas.log"
afirmar "arquivo fora do HOME: avisa" bash -c 'cat "$1" "$2" | grep -q "usuário mantido"' _ "$TMP/out" "$TMP/err"
afirmar "arquivo fora do HOME: o HOME e o .conf somem mesmo assim" test ! -e "$(H exemplo)" -a ! -e "$RAIZ_T/etc/runner-vps/exemplo.conf"

# config.sh remove falhando: nada é apagado
nova_vps
instalar exemplo
antes="$(snapshot "$RAIZ_T")"
CONFIG_SAIDA=1 RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" rodar --remover; codigo=$?
afirmar "config.sh remove falhando: saída 1" test "$codigo" -eq 1
afirmar "config.sh remove falhando: nada apagado" test "$antes" = "$(snapshot "$RAIZ_T")"
afirmar "config.sh remove falhando: o usuário continua" bash -c '! grep -q "^userdel" "$1"' _ "$TMP/chamadas.log"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"

# instância que não existe
nova_vps
RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" rodar --remover; codigo=$?
afirmar "remover instância inexistente: saída 1" test "$codigo" -eq 1

# DOCKER_ROOTLESS=0: não mexe no rootless
nova_vps
DOCKER_ROOTLESS=0 instalar exemplo
RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" rodar --remover
afirmar "remover sem rootless: não chama o rootless nem o docker" bash -c '! grep -qE "^rootless|disable --now docker" "$1"' _ "$TMP/chamadas.log"

relatorio "instalar.sh (status e remover)"
