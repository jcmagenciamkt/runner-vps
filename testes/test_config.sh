#!/usr/bin/env bash
# Testes de --listar e --config do instalar.sh (Task 13 do plano): somente leitura, contra a VPS falsa.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
URL=https://github.com/dono/repo
rodar() { bash "$script" "$@" > "$TMP/out" 2> "$TMP/err"; }
saida_tem() { grep -qF -- "$1" "$TMP/out"; }
instalar() { # <nome> [VAR=valor…]
  local n="$1"; shift
  env RUNNER_NOME="$n" RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" "$@" bash "$script" > "$TMP/out" 2> "$TMP/err"
}

echo "instalar.sh --listar"
nova_vps
env -u RUNNER_NOME bash "$script" --listar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem instâncias: saída 0 e nada na saída" test "$codigo" -eq 0 -a ! -s "$TMP/out" -a ! -s "$TMP/err"
MEM_LIVRE_MB=16384 nova_vps
instalar zeta MEMORY_MAX_MB=2048; instalar alfa MEMORY_MAX_MB=2048
antes="$(snapshot "$TMP/raiz")"; : > "$TMP/chamadas.log"
env -u RUNNER_NOME bash "$script" --listar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "com duas instâncias: saída 0" test "$codigo" -eq 0
afirmar "lista os nomes, um por linha e em ordem" test "$(cat "$TMP/out")" = "$(printf 'alfa\nzeta')"
afirmar "só somente leitura: nada mudou e nenhum comando com efeito foi chamado" test "$antes" = "$(snapshot "$TMP/raiz")" -a ! -s "$TMP/chamadas.log"
RUNNER_NOME=Invalido bash "$script" --listar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "nome informado e inválido continua recusado (saída 2)" test "$codigo" -eq 2

echo "instalar.sh --config"
MEM_LIVRE_MB=16384 nova_vps
instalar exemplo MEMORY_MAX_MB=3072 CPU_QUOTA=150 RUNNER_ROTULOS=ci,gpu HOSTS_EXTRAS='127.0.0.1 a.exemplo.test'
antes="$(snapshot "$TMP/raiz")"; : > "$TMP/chamadas.log"
RUNNER_NOME=exemplo rodar --config; codigo=$?
afirmar "saída 0" test "$codigo" -eq 0
afirmar "mostra a URL do runner" saida_tem "RUNNER_URL=$URL"
afirmar "mostra o limite de memória e a cota de CPU gravados" test "$(grep -c -E '^(MEMORY_MAX_MB=3072|CPU_QUOTA=150)$' "$TMP/out")" -eq 2
afirmar "mostra os rótulos, a reserva e o mínimo" test "$(grep -c -E '^(RUNNER_ROTULOS=ci,gpu|RESERVA_MB=1024|MEM_MIN_MB=2048)$' "$TMP/out")" -eq 3
afirmar "mostra os hosts extras sem escapes" saida_tem 'HOSTS_EXTRAS=127.0.0.1 a.exemplo.test'
afirmar "todas as linhas são CHAVE=valor" test "$(grep -vc -E '^[A-Z][A-Z0-9_]*=' "$TMP/out")" -eq 0
afirmar "não mostra o token" bash -c '! grep -q "$2" "$1"' _ "$TMP/out" "$TOKEN_FALSO"
afirmar "não há RUNNER_TOKEN na saída (o token nunca é gravado)" bash -c '! grep -q RUNNER_TOKEN "$1"' _ "$TMP/out"
afirmar "somente leitura" test "$antes" = "$(snapshot "$TMP/raiz")" -a ! -s "$TMP/chamadas.log"
afirmar "sem erro" test ! -s "$TMP/err"
RUNNER_NOME=inexistente rodar --config; codigo=$?
afirmar "instância inexistente: saída 1 com mensagem" test "$codigo" -eq 1 -a "$(grep -c 'não existe' "$TMP/err")" -eq 1
env -u RUNNER_NOME bash "$script" --config > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "--config sem RUNNER_NOME: saída 2" test "$codigo" -eq 2

relatorio "instalar.sh (listar e config)"
