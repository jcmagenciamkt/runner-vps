#!/usr/bin/env bash
# Roda todos os testes/test_*.sh, cada um em processo próprio. Sai com 1 se algum falhar.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
falhou=0
for t in "$aqui"/test_*.sh; do
  [ -e "$t" ] || continue
  printf '== %s\n' "$(basename "$t")"
  bash "$t" || falhou=1
done
if [ "$falhou" -ne 0 ]; then echo "TESTES FALHARAM"; exit 1; fi
echo "TODOS OS TESTES PASSARAM"
