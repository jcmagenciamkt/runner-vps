#!/usr/bin/env bash
# Testes do gancho-fim.sh (Task 4 do plano) e da cópia embutida no instalar.sh.
set -uo pipefail
aqui="$(cd "$(dirname "$0")" && pwd)"
gancho="$aqui/../gancho-fim.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

# docker falso: registra a chamada; `compose ls -q` lista dois projetos; DOCKER_SAIDA define o código.
cat > "$TMP/bin/docker-gancho" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "docker $*" >> "$TMP/chamadas.log"
if [ "$*" = "compose ls -q" ] && [ "${DOCKER_SAIDA:-0}" = 0 ]; then printf 'a\nb\n'; fi
exit "${DOCKER_SAIDA:-0}"
FALSO
printf '#!/usr/bin/env bash\nprintf "Avail\\n %%sG\\n" 40\n' > "$TMP/bin/df-gancho"
chmod +x "$TMP/bin/docker-gancho" "$TMP/bin/df-gancho"
export DOCKER_CMD="$TMP/bin/docker-gancho" DF_CMD="$TMP/bin/df-gancho" AGORA=1700000000
export LOG_FILE="$TMP/runner-vps.log" GITHUB_JOB=build GITHUB_RUN_ID=42
rodar() { bash "$gancho" > "$TMP/out" 2> "$TMP/err"; }
linha_de() { grep -nF -- "$1" "$TMP/chamadas.log" | head -n 1 | cut -d: -f1; }

echo "gancho-fim.sh"

# 1. com DOCKER_HOST: derruba cada projeto do compose e limpa, nessa ordem
: > "$TMP/chamadas.log"
DOCKER_HOST=unix:///run/user/2001/docker.sock rodar; codigo=$?
afirmar "sai com 0" test "$codigo" -eq 0
afirmar "lista os projetos do compose" grep -qxF "docker compose ls -q" "$TMP/chamadas.log"
afirmar "derruba o projeto a" grep -qxF "docker compose -p a down -v --remove-orphans" "$TMP/chamadas.log"
afirmar "derruba o projeto b" grep -qxF "docker compose -p b down -v --remove-orphans" "$TMP/chamadas.log"
afirmar "faz o prune de 24h" grep -qxF "docker system prune -f --filter until=24h" "$TMP/chamadas.log"
afirmar "ordem: ls, down a, down b, prune" \
  test "$(linha_de 'compose ls -q')" -lt "$(linha_de 'compose -p a down')" -a "$(linha_de 'compose -p a down')" -lt "$(linha_de 'compose -p b down')" -a "$(linha_de 'compose -p b down')" -lt "$(linha_de 'system prune')"

# 3. a linha do log
afirmar "uma linha no log" test "$(wc -l < "$LOG_FILE")" -eq 1
afirmar "a linha tem data (de AGORA), job, run, docker e disco" \
  grep -qxF "2023-11-14T22:13:20Z job=build run=42 docker=ok disco=40G" "$LOG_FILE"

# 2. sem DOCKER_HOST: nenhuma chamada ao Docker
: > "$TMP/chamadas.log"; : > "$LOG_FILE"
env -u DOCKER_HOST bash "$gancho" > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem DOCKER_HOST: sai com 0" test "$codigo" -eq 0
afirmar "sem DOCKER_HOST: nenhuma chamada ao Docker" test ! -s "$TMP/chamadas.log"
afirmar "sem DOCKER_HOST: o log diz que pulou o Docker" grep -q "docker=pulado" "$LOG_FILE"
DOCKER_HOST='' rodar
afirmar "DOCKER_HOST vazio também pula o Docker" test ! -s "$TMP/chamadas.log"

# 4. Docker falhando: sai com 0 e registra a falha
: > "$TMP/chamadas.log"; : > "$LOG_FILE"
DOCKER_SAIDA=1 DOCKER_HOST=unix:///run/user/2001/docker.sock rodar; codigo=$?
afirmar "docker falhando: sai com 0" test "$codigo" -eq 0
afirmar "docker falhando: o log registra docker=falhou" grep -q "docker=falhou" "$LOG_FILE"
afirmar "docker falhando: ainda grava uma só linha" test "$(wc -l < "$LOG_FILE")" -eq 1

# log em lugar impossível de gravar: ainda sai com 0
LOG_FILE="$TMP/nao-existe/dir/log" env -u DOCKER_HOST bash "$gancho" > /dev/null 2>&1; codigo=$?
afirmar "sem poder gravar o log: sai com 0" test "$codigo" -eq 0

# 5. o texto do script
afirmar "o gancho não referencia o socket do Docker de root" bash -c '! grep -q "/var/run/docker.sock" "$1"' _ "$gancho"
afirmar "o gancho não usa sudo" bash -c '! grep -qw sudo "$1"' _ "$gancho"
afirmar "o gancho tem o cabeçalho e o set do projeto" \
  bash -c 'head -n 1 "$1" | grep -qx "#!/usr/bin/env bash" && grep -qx "set -euo pipefail" "$1"' _ "$gancho"

echo "gancho-fim.sh embutido no instalar.sh"
nova_vps
RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo bash "$aqui/../instalar.sh" > /dev/null 2>&1
instalado="$TMP/raiz/opt/runner-vps/exemplo/bin/gancho-fim.sh"
afirmar "o gancho instalado é idêntico ao gancho-fim.sh do repositório" cmp -s "$instalado" "$gancho"
afirmar "o gancho instalado é executável" test -x "$instalado"

relatorio "gancho-fim.sh"
