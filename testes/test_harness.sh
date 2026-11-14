#!/usr/bin/env bash
# Teste de fumaça do harness e da VPS falsa.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

echo "harness"

# comando_falso registra a chamada (com argumentos) e devolve o código e o texto pedidos
comando_falso exemplo-cmd 3 "saida com espaços"
saida="$(exemplo-cmd um 'dois três')"; codigo=$?
afirmar "comando falso devolve o código pedido" test "$codigo" -eq 3
afirmar "comando falso imprime o texto pedido" test "$saida" = "saida com espaços"
afirmar "comando falso registra nome e argumentos" grep -qxF 'exemplo-cmd um dois três' "$TMP/chamadas.log"
afirmar "chamadas filtra por nome" test "$(chamadas exemplo-cmd | wc -l)" -eq 1

# afirmar_sem: arquivo, diretório e texto
mkdir -p "$TMP/d"; printf 'nada aqui\n' > "$TMP/d/a"
afirmar_sem "$TMP/d" "SEGREDO"
afirmar_sem "texto sem nada" "SEGREDO"
printf 'tem SEGREDO\n' > "$TMP/d/b"
( afirmar_sem "$TMP/d" "SEGREDO" > "$TMP/saida-sem" )
afirmar "afirmar_sem acusa o segredo presente" test "$(grep -c FALHA "$TMP/saida-sem")" -eq 1
afirmar "afirmar_sem não imprime o segredo" bash -c '! grep -q SEGREDO "$1"' _ "$TMP/saida-sem"

# snapshot: igual sem mudança; muda com conteúdo e com mtime
a="$(snapshot "$TMP/d")"; b="$(snapshot "$TMP/d")"
afirmar "snapshot estável sem mudanças" test "$a" = "$b"
sleep 0.01; touch "$TMP/d/a"
afirmar "snapshot detecta mudança só de mtime" test "$a" != "$(snapshot "$TMP/d")"

# VPS falsa
montar_vps_falsa
afirmar "meminfo falso tem MemAvailable de 6144 MB" grep -q "MemAvailable: *$((6144 * 1024)) kB" "$MEMINFO_FILE"
afirmar "nproc falso devolve 4" test "$("$NPROC_CMD")" = 4
afirmar "df falso devolve 40G" bash -c '"$1" | tail -1 | grep -q 40G' _ "$DF_CMD"
afirmar "tarball falso confere o sha256" test "$(sha256sum "$RUNNER_TARBALL" | cut -d' ' -f1)" = "$RUNNER_SHA256"
"$BAIXAR_CMD" https://exemplo.invalid/runner.tgz "$TMP/baixado.tgz"
afirmar "BAIXAR_CMD copia o tarball sem rede" cmp -s "$TMP/baixado.tgz" "$RUNNER_TARBALL"
mkdir -p "$TMP/ext"; tar -C "$TMP/ext" -xzf "$TMP/baixado.tgz"
"$TMP/ext/config.sh" --unattended
afirmar "config.sh falso registra a chamada" grep -qxF 'config.sh --unattended' "$TMP/chamadas.log"
CONFIG_SAIDA=1 "$TMP/ext/config.sh" || codigo=$?
afirmar "config.sh falso pode falhar (CONFIG_SAIDA=1)" test "${codigo:-0}" -eq 1
afirmar "CONFIG_CMD falso registra e obedece CONFIG_SAIDA" bash -c '"$1" --unattended; c=$?; CONFIG_SAIDA=2 "$1"; d=$?; [ "$c" = 0 ] && [ "$d" = 2 ]' _ "$CONFIG_CMD"
afirmar "ARQUIVOS_DO_USUARIO_CMD falso não lista nada" test -z "$("$ARQUIVOS_DO_USUARIO_CMD" runner-exemplo)"
afirmar "RAIZ falsa tem etc/hosts, subuid e subgid" test -f "$RAIZ/etc/hosts" -a -f "$RAIZ/etc/subuid" -a -f "$RAIZ/etc/subgid"

# parâmetros da VPS falsa
MEM_LIVRE_MB=2560 CPUS=1 montar_vps_falsa
afirmar "parâmetros mudam o meminfo e o nproc" bash -c 'grep -q "MemAvailable: *2621440 kB" "$1" && [ "$("$2")" = 1 ]' _ "$MEMINFO_FILE" "$NPROC_CMD"

relatorio harness
