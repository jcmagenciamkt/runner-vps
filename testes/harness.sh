#!/usr/bin/env bash
# Harness dos testes: comandos falsos, asserções, snapshot e relatório. Uso: `source testes/harness.sh`.
# Bash puro, sem rede, sem root. Não define `set -e`: um teste que falha não deve abortar os demais.

HARNESS_FALHAS=0
HARNESS_OK=0

# Diretório temporário do teste; o chamador pode definir TMP antes de carregar o harness.
if [ -z "${TMP:-}" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
fi
export TMP
mkdir -p "$TMP/bin"
: > "$TMP/chamadas.log"
export PATH="$TMP/bin:$PATH"

# comando_falso <nome> [codigo_saida] [texto_stdout]
# Cria $TMP/bin/<nome>: registra "nome args…" em $TMP/chamadas.log, imprime o texto e sai com o código.
comando_falso() {
  local nome="$1" codigo="${2:-0}" saida="${3:-}" linha_saida=""
  [ -n "$saida" ] && linha_saida="$(printf 'printf "%%s\\n" %q' "$saida")"
  cat > "$TMP/bin/$nome" <<CORPO
#!/usr/bin/env bash
printf '%s\n' "$nome \$*" >> "$TMP/chamadas.log"
$linha_saida
exit $codigo
CORPO
  chmod +x "$TMP/bin/$nome"
}

# chamadas [nome]: imprime o registro de chamadas (todas, ou só as do comando dado).
chamadas() {
  if [ -n "${1:-}" ]; then grep -E "^$1( |$)" "$TMP/chamadas.log" || true; else cat "$TMP/chamadas.log"; fi
}

# afirmar <descricao> <comando> [args…]  — ok se o comando sai com 0.
# Também aceita <descricao> <codigo_numerico> (status já calculado).
afirmar() {
  local desc="$1"; shift
  local status
  if [ "$#" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then status="$1"; else "$@" > /dev/null 2>&1; status=$?; fi
  if [ "$status" -eq 0 ]; then
    printf '  ok    %s\n' "$desc"; HARNESS_OK=$((HARNESS_OK + 1))
  else
    printf '  FALHA %s\n' "$desc"; HARNESS_FALHAS=$((HARNESS_FALHAS + 1))
  fi
}

# afirmar_sem <arquivo_diretorio_ou_texto> <segredo>
# Passa se o segredo não aparece (em nenhum arquivo, se for diretório). Imprime só a descrição, nunca o segredo.
afirmar_sem() {
  local alvo="$1" segredo="$2" achou=1
  if [ -d "$alvo" ]; then grep -rqF -- "$segredo" "$alvo" && achou=0
  elif [ -f "$alvo" ]; then grep -qF -- "$segredo" "$alvo" && achou=0
  else case "$alvo" in *"$segredo"*) achou=0 ;; esac; fi
  if [ "$achou" -ne 0 ]; then
    printf '  ok    segredo ausente\n'; HARNESS_OK=$((HARNESS_OK + 1))
  else
    printf '  FALHA segredo presente em %s\n' "$([ -e "$alvo" ] && echo "$alvo" || echo 'texto')"; HARNESS_FALHAS=$((HARNESS_FALHAS + 1))
  fi
}

# snapshot <dir>: uma linha por arquivo (caminho, mtime em ns, sha256), ordenada. Compare duas saídas.
snapshot() {
  local dir="$1"
  ( cd "$dir" && find . -type f -print0 | sort -z | while IFS= read -r -d '' f; do
      printf '%s %s %s\n' "$f" "$(stat -c %.9Y "$f")" "$(sha256sum < "$f" | cut -d' ' -f1)"
    done )
}

# relatorio <titulo>: resumo e código de saída (1 se houve falha).
relatorio() {
  if [ "$HARNESS_FALHAS" -eq 0 ]; then
    printf '%s: tudo certo (%s ok)\n' "$1" "$HARNESS_OK"; return 0
  fi
  printf '%s: %s falha(s), %s ok\n' "$1" "$HARNESS_FALHAS" "$HARNESS_OK"; return 1
}
