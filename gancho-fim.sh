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
