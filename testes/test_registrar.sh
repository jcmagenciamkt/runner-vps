#!/usr/bin/env bash
# Testes do registrar.sh com gh e ssh falsos. Sem rede. Autossuficiente (não usa o harness ainda;
# a Task 1 do plano pode migrá-lo).
set -uo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../registrar.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

falhas=0
afirmar() { # descrição, condição (0 = ok)
  if [ "$2" -eq 0 ]; then printf '  ok   %s\n' "$1"; else printf '  FALHA %s\n' "$1"; falhas=$((falhas + 1)); fi
}

TOKEN_FALSO="AAAATOKENSECRETO123456"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/gh.log"
printf '%s\n' "$TOKEN_FALSO"
EOF
cat > "$tmp/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/ssh.args"
cat > "$tmp/ssh.stdin"
EOF
printf '#!/usr/bin/env bash\necho INSTALADOR FALSO "\$@"\n' > "$tmp/instalar.sh"
chmod +x "$tmp/bin/gh" "$tmp/bin/ssh"

export GH_CMD="$tmp/bin/gh" SSH_CMD="$tmp/bin/ssh" INSTALAR_SH="$tmp/instalar.sh"

rodar() { bash "$script" "$@" > "$tmp/out" 2> "$tmp/err"; echo $?; }
limpar() { rm -f "$tmp/gh.log" "$tmp/ssh.args" "$tmp/ssh.stdin" "$tmp/out" "$tmp/err"; }

echo "registrar.sh"

# 1. instalar: token pela API, vai pelo stdin, não aparece em saída nem em argumentos
limpar
codigo="$(rodar --vps root@vps.exemplo:2222 --repo dono/repo --nome exemplo --rotulos a,b --chave "$tmp/chave")"
afirmar "instalar sai com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "gh chamado com registration-token do repositório" "$(grep -q 'api -X POST repos/dono/repo/actions/runners/registration-token' "$tmp/gh.log"; echo $?)"
afirmar "ssh recebe -i, -p 2222 e bash -s" "$(grep -q -- "-i $tmp/chave -p 2222 -o BatchMode=yes root@vps.exemplo bash -s -- " "$tmp/ssh.args"; echo $?)"
afirmar "stdin do ssh tem RUNNER_TOKEN, RUNNER_URL, RUNNER_NOME, RUNNER_ROTULOS" \
  "$(grep -q "export RUNNER_TOKEN=$TOKEN_FALSO" "$tmp/ssh.stdin" && grep -q 'export RUNNER_URL=https://github.com/dono/repo' "$tmp/ssh.stdin" \
     && grep -q 'export RUNNER_NOME=exemplo' "$tmp/ssh.stdin" && grep -q 'export RUNNER_ROTULOS=a\\,b' "$tmp/ssh.stdin"; echo $?)"
# (printf %q escapa a vírgula; o bash remoto lê "a,b" de volta)
afirmar "stdin do ssh termina com o instalar.sh" "$(grep -q 'INSTALADOR FALSO' "$tmp/ssh.stdin"; echo $?)"
afirmar "token não aparece na saída, no erro nem nos argumentos do ssh" \
  "$(! grep -q "$TOKEN_FALSO" "$tmp/out" "$tmp/err" "$tmp/ssh.args"; echo $?)"

# 2. --org usa orgs/<org>
limpar
rodar --vps root@vps.exemplo --org minha-org --nome exemplo > /dev/null
afirmar "--org chama orgs/minha-org" "$(grep -q 'orgs/minha-org/actions/runners/registration-token' "$tmp/gh.log"; echo $?)"
afirmar "RUNNER_URL da organização" "$(grep -q 'export RUNNER_URL=https://github.com/minha-org' "$tmp/ssh.stdin"; echo $?)"

# 3. --so-checar e --status: sem token, sem gh, argumento certo
for m in so-checar status; do
  limpar
  codigo="$(rodar --vps root@vps.exemplo --nome exemplo "--$m")"
  afirmar "--$m sai com 0 sem --repo" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
  afirmar "--$m não chama o gh" "$([ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"
  afirmar "--$m não envia RUNNER_TOKEN" "$(! grep -q RUNNER_TOKEN "$tmp/ssh.stdin"; echo $?)"
  afirmar "--$m repassa o argumento ao instalar.sh" "$(grep -q -- "bash -s -- --$m" "$tmp/ssh.args"; echo $?)"
done

# 4. --remover: remove-token, argumento --remover
limpar
rodar --vps root@vps.exemplo --repo dono/repo --nome exemplo --remover > /dev/null
afirmar "--remover usa remove-token" "$(grep -q 'actions/runners/remove-token' "$tmp/gh.log"; echo $?)"
afirmar "--remover repassa --remover" "$(grep -q -- 'bash -s -- --remover' "$tmp/ssh.args"; echo $?)"

# 5. --sem-token: sem gh, instala sem RUNNER_TOKEN
limpar
rodar --vps root@vps.exemplo --nome exemplo --sem-token > /dev/null
afirmar "--sem-token não chama o gh e não envia token" "$([ ! -e "$tmp/gh.log" ] && ! grep -q RUNNER_TOKEN "$tmp/ssh.stdin" && echo 0 || echo 1)"

# 6. --var e --sem-docker entram como export, com valor escapado
limpar
rodar --vps root@vps.exemplo --repo dono/repo --nome exemplo --sem-docker --var 'HOSTS_EXTRAS=127.0.0.1 a.localhost b.localhost' --var RESERVA_MB=2048 > /dev/null
afirmar "--sem-docker vira DOCKER_ROOTLESS=0" "$(grep -q 'export DOCKER_ROOTLESS=0' "$tmp/ssh.stdin"; echo $?)"
afirmar "--var com espaço fica escapado" "$(grep -q 'export HOSTS_EXTRAS=127.0.0.1\\ a.localhost\\ b.localhost' "$tmp/ssh.stdin"; echo $?)"
afirmar "--var simples" "$(grep -q 'export RESERVA_MB=2048' "$tmp/ssh.stdin"; echo $?)"

# 7. --mostrar: não conecta, não chama gh, token redigido
limpar
codigo="$(rodar --vps root@vps.exemplo --repo dono/repo --nome exemplo --mostrar)"
afirmar "--mostrar sai com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "--mostrar não chama ssh nem gh" "$([ ! -e "$tmp/ssh.args" ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"
afirmar "--mostrar redige o token" "$(grep -q 'RUNNER_TOKEN=<redigido>' "$tmp/out"; echo $?)"

# 8. erros de uso: saída 2 e nada enviado
limpar
afirmar "sem --vps: saída 2" "$([ "$(rodar --nome exemplo --repo dono/repo)" = 2 ] && echo 0 || echo 1)"
afirmar "nome inválido: saída 2" "$([ "$(rodar --vps root@v --repo dono/repo --nome 'Ex emplo')" = 2 ] && echo 0 || echo 1)"
afirmar "instalar sem --repo/--org: saída 2" "$([ "$(rodar --vps root@v --nome exemplo)" = 2 ] && echo 0 || echo 1)"
afirmar "--repo e --org juntos: saída 2" "$([ "$(rodar --vps root@v --repo a/b --org c --nome exemplo)" = 2 ] && echo 0 || echo 1)"
afirmar "--var RUNNER_TOKEN=…: saída 2" "$([ "$(rodar --vps root@v --repo a/b --nome exemplo --var RUNNER_TOKEN=x)" = 2 ] && echo 0 || echo 1)"
afirmar "porta inválida: saída 2" "$([ "$(rodar --vps root@v:abc --repo a/b --nome exemplo)" = 2 ] && echo 0 || echo 1)"
afirmar "nenhum erro de uso chamou o ssh" "$([ ! -e "$tmp/ssh.args" ] && echo 0 || echo 1)"

# 9. gh falhando: saída 1, mensagem sem token, ssh não chamado
limpar
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/gh"
codigo="$(rodar --vps root@vps.exemplo --repo dono/repo --nome exemplo)"
afirmar "gh falhando: saída 1 e ssh não chamado" "$([ "$codigo" = 1 ] && [ ! -e "$tmp/ssh.args" ] && echo 0 || echo 1)"

# 10. instalar.sh ausente: saída 1
limpar
codigo="$(INSTALAR_SH=/caminho/inexistente bash "$script" --vps root@v --nome exemplo --status >/dev/null 2>&1; echo $?)"
afirmar "instalar.sh ausente: saída 1" "$([ "$codigo" = 1 ] && echo 0 || echo 1)"

# 11. o texto do script não ecoa o token
afirmar "registrar.sh não contém 'echo \"\$token' nem set -x" "$(! grep -qE 'echo .*\$token|set -x' "$script"; echo $?)"

# 13. --quieto esconde as linhas de andamento (==>); sem ele, aparecem
limpar
rodar --vps root@vps.exemplo --nome exemplo --status > /dev/null
afirmar "sem --quieto: a linha de andamento aparece" "$(grep -q '^==> Enviando o instalar.sh' "$tmp/out"; echo $?)"
limpar
rodar --vps root@vps.exemplo --nome exemplo --status --quieto > /dev/null
afirmar "com --quieto: nenhuma linha ==> na saída" "$(! grep -q '^==>' "$tmp/out"; echo $?)"
afirmar "com --quieto: o ssh ainda é chamado normalmente" "$(grep -q -- 'bash -s -- --status' "$tmp/ssh.args"; echo $?)"
limpar
# (o gh falso foi trocado por um que falha no cenário 9; volta o que devolve o token)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$TOKEN_FALSO" > "$tmp/bin/gh"
rodar --vps root@vps.exemplo --repo dono/repo --nome exemplo --quieto > /dev/null
afirmar "com --quieto: o token ainda vai pelo stdin e não aparece na saída" "$(grep -q "export RUNNER_TOKEN=$TOKEN_FALSO" "$tmp/ssh.stdin" && ! grep -q "$TOKEN_FALSO" "$tmp/out" "$tmp/err"; echo $?)"

# 12. os scripts de entrada são executáveis (o README manda rodar ./registrar.sh)
for f in registrar.sh instalar.sh gancho-fim.sh; do
  afirmar "$f tem o bit de execução" "$([ -x "$aqui/../$f" ] && echo 0 || echo 1)"
done

if [ "$falhas" -eq 0 ]; then echo "registrar.sh: tudo certo"; exit 0; fi
echo "registrar.sh: $falhas falha(s)"; exit 1
