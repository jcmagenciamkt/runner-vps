#!/usr/bin/env bash
# Testes de --local (instalar nesta máquina, sem SSH) e --repos (uma instância por repositório) do registrar.sh
# (Task 15 do plano), com gh, ssh, sudo e o shell local falsos. Sem rede, sem root.
set -uo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../registrar.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

falhas=0; oks=0
afirmar() { # descrição, condição (0 = ok)
  if [ "$2" -eq 0 ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1)); else printf '  FALHA %s\n' "$1"; falhas=$((falhas + 1)); fi
}

TOKEN_FALSO="AAAATOKENSECRETO123456"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/gh.log"
printf '%s\n' "$TOKEN_FALSO"
EOF2
# ssh falso e shell local falso (mesmo corpo): cada chamada grava args e stdin em arquivos numerados.
# O --so-checar responde o veredito (MEMMAX, em MB; CABE=nao faz "não cabe"); FALHA_NOME faz a instalação dessa instância falhar.
cat > "$tmp/bin/executor" <<EOF2
#!/usr/bin/env bash
t="$tmp"
n=\$(( \$(cat "\$t/n" 2> /dev/null || echo 0) + 1 )); echo "\$n" > "\$t/n"
printf '%s %s\n' "\$(basename "\$0")" "\$*" > "\$t/c.\$n.args"
cat > "\$t/c.\$n.stdin"
case "\$*" in
  *"-s -- --so-checar"*)
    if [ "\${CABE:-sim}" = erro ]; then echo 'ERRO: rode como root.'; exit 1; fi
    if [ "\${CABE:-sim}" = nao ]; then echo 'VEREDITO: não cabe: memória (mínimo 2048)'; exit 1; fi
    echo "VEREDITO: cabe (MemoryMax=\${MEMMAX:-4096}M CPUQuota=200%)"; exit 0 ;;
esac
if [ -n "\${FALHA_NOME:-}" ] && grep -q "RUNNER_NOME=\$FALHA_NOME\$" "\$t/c.\$n.stdin"; then exit 1; fi
exit 0
EOF2
ln -s executor "$tmp/bin/ssh"; ln -s executor "$tmp/bin/shell-local"
cat > "$tmp/bin/sudo" <<EOF2
#!/usr/bin/env bash
printf '%s\n' "sudo \$*" >> "$tmp/sudo.log"
exec "\$@"
EOF2
printf '#!/usr/bin/env bash\necho INSTALADOR FALSO "$@"\n' > "$tmp/instalar.sh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in -s) echo Linux ;; *) echo Linux ;; esac\n' > "$tmp/bin/uname-linux"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$tmp/bin/uname-mac"
chmod +x "$tmp/bin/gh" "$tmp/bin/executor" "$tmp/bin/sudo" "$tmp/bin/uname-linux" "$tmp/bin/uname-mac"

export GH_CMD="$tmp/bin/gh" SSH_CMD="$tmp/bin/ssh" BASH_LOCAL_CMD="$tmp/bin/shell-local" SUDO_CMD="$tmp/bin/sudo" \
  INSTALAR_SH="$tmp/instalar.sh" UNAME_CMD="$tmp/bin/uname-linux" UID_ATUAL=0

limpar() { rm -f "$tmp"/c.* "$tmp"/n "$tmp"/gh.log "$tmp"/sudo.log "$tmp/out" "$tmp/err"; unset CABE MEMMAX FALHA_NOME; }
rodar() { bash "$script" "$@" > "$tmp/out" 2> "$tmp/err"; echo $?; }
ncalls() { ls "$tmp"/c.*.args 2> /dev/null | wc -l; }
tem() { grep -qE -- "$2" "$tmp/c.$1.args"; }       # <n> <padrão>: os argumentos da chamada n
stdin_tem() { grep -qE -- "$2" "$tmp/c.$1.stdin"; } # <n> <padrão>
gh_vezes() { [ -f "$tmp/gh.log" ] && grep -c "$1" "$tmp/gh.log" || echo 0; }

echo "--local"
limpar
codigo="$(rodar --local --repo dono/repo --nome exemplo)"
afirmar "como root: instala sem ssh, direto no shell local (saída 0)" "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 1 ] && tem 1 '^shell-local -s -- *$' && echo 0 || echo 1)"
afirmar "como root: não usa sudo" "$([ ! -e "$tmp/sudo.log" ] && echo 0 || echo 1)"
afirmar "o token vai pelo stdin do shell local, com RUNNER_NOME e RUNNER_URL" \
  "$(stdin_tem 1 "export RUNNER_TOKEN=$TOKEN_FALSO" && stdin_tem 1 'export RUNNER_NOME=exemplo' && stdin_tem 1 'export RUNNER_URL=https://github.com/dono/repo' && stdin_tem 1 'INSTALADOR FALSO'; echo $?)"
afirmar "o token não aparece na saída, no erro nem nos argumentos" "$(! grep -q "$TOKEN_FALSO" "$tmp/out" "$tmp/err" "$tmp"/c.*.args "$tmp/gh.log" 2> /dev/null; echo $?)"
afirmar "o gh gerou o token de registro do repositório" "$([ "$(gh_vezes 'repos/dono/repo/actions/runners/registration-token')" = 1 ] && echo 0 || echo 1)"

limpar
UID_ATUAL=1000 rodar --local --repo dono/repo --nome exemplo > /dev/null
afirmar "sem ser root: usa sudo e o token continua só no stdin" \
  "$(grep -qxF "sudo $tmp/bin/shell-local -s --" "$tmp/sudo.log" && stdin_tem 1 "export RUNNER_TOKEN=$TOKEN_FALSO" && ! grep -q "$TOKEN_FALSO" "$tmp/sudo.log" "$tmp"/c.*.args; echo $?)"

limpar
codigo="$(UID_ATUAL=1000 SUDO_CMD="$tmp/bin/nao-existe" rodar --local --repo dono/repo --nome exemplo)"
afirmar "sem root e sem sudo: saída 1, explica e não gera token nem executa" "$([ "$codigo" = 1 ] && grep -q 'root' "$tmp/err" && [ "$(ncalls)" = 0 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"

limpar
codigo="$(UNAME_CMD="$tmp/bin/uname-mac" rodar --local --repo dono/repo --nome exemplo)"
afirmar "fora do Linux: saída 1 e nada é executado nem gerado" "$([ "$codigo" = 1 ] && grep -q 'Linux' "$tmp/err" && [ "$(ncalls)" = 0 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"

limpar
afirmar "--local e --vps juntos: saída 2" "$([ "$(rodar --local --vps root@v --repo a/b --nome x)" = 2 ] && echo 0 || echo 1)"
afirmar "--local com --chave: saída 2" "$([ "$(rodar --local --chave /tmp/k --repo a/b --nome x)" = 2 ] && echo 0 || echo 1)"
afirmar "nada foi executado nesses erros" "$([ "$(ncalls)" = 0 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"

for m in so-checar status config sem-token; do
  limpar
  codigo="$(rodar --local --nome exemplo --$m --quieto)"
  esperado="--$m"; [ "$m" = sem-token ] && esperado=''
  afirmar "--local --$m: roda no shell local, sem ssh e sem gh" \
    "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 1 ] && tem 1 "^shell-local -s -- *$esperado\$" && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"
done
limpar
codigo="$(rodar --local --listar --quieto)"
afirmar "--local --listar dispensa --nome" "$([ "$codigo" = 0 ] && tem 1 '^shell-local -s -- --listar$' && echo 0 || echo 1)"
limpar
codigo="$(rodar --local --repo dono/repo --nome exemplo --remover --quieto)"
afirmar "--local --remover: token de remoção pelo stdin" "$([ "$codigo" = 0 ] && tem 1 '^shell-local -s -- --remover$' && stdin_tem 1 "export RUNNER_TOKEN=$TOKEN_FALSO" && echo 0 || echo 1)"

limpar
codigo="$(rodar --local --repo dono/repo --nome exemplo --mostrar)"
afirmar "--local --mostrar: não executa nem gera token, e mostra o comando com o token redigido" \
  "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 0 ] && [ ! -e "$tmp/gh.log" ] && grep -q 'RUNNER_TOKEN=<redigido>' "$tmp/out" && grep -q 'shell-local -s --' "$tmp/out" && echo 0 || echo 1)"

echo "--repos"
limpar
codigo="$(rodar --vps root@vps.exemplo --repos dono/alfa,dono/Beta_X.y --quieto)"
afirmar "dois repositórios: saída 0 e três chamadas (painel, alfa e beta-x-y)" "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 3 ] && echo 0 || echo 1)"
afirmar "a primeira chamada é o painel do servidor, sem nome, URL nem token" \
  "$(tem 1 'bash -s -- --so-checar' && ! stdin_tem 1 'RUNNER_(NOME|URL|TOKEN)'; echo $?)"
afirmar "cada repositório vira uma instância com nome derivado e a sua URL" \
  "$(stdin_tem 2 'export RUNNER_NOME=alfa$' && stdin_tem 2 'RUNNER_URL=https://github.com/dono/alfa$' && stdin_tem 3 'export RUNNER_NOME=beta-x-y$' && stdin_tem 3 'RUNNER_URL=https://github.com/dono/Beta_X.y$'; echo $?)"
afirmar "a memória do servidor (4096 MB) é dividida em partes iguais: 2048 MB cada" \
  "$(stdin_tem 2 'export MEMORY_MAX_MB=2048$' && stdin_tem 3 'export MEMORY_MAX_MB=2048$'; echo $?)"
afirmar "um token por repositório, gerado só depois do painel, e só no stdin de cada instalação" \
  "$([ "$(gh_vezes registration-token)" = 2 ] && grep -q 'repos/dono/alfa/' "$tmp/gh.log" && grep -q 'repos/dono/Beta_X.y/' "$tmp/gh.log" && stdin_tem 2 "RUNNER_TOKEN=$TOKEN_FALSO" && stdin_tem 3 "RUNNER_TOKEN=$TOKEN_FALSO" && ! grep -q "$TOKEN_FALSO" "$tmp/out" "$tmp/err" "$tmp"/c.*.args "$tmp/c.1.stdin"; echo $?)"
afirmar "o resumo diz o MemoryMax de cada uma" "$(grep -q 'MemoryMax=2048M' "$tmp/out"; echo $?)"

limpar
codigo="$(MEMMAX=4096 rodar --vps root@v --repos dono/a,dono/b,dono/c --quieto)"
afirmar "três repositórios em 4096 MB: cada um teria 1280 MB, abaixo do mínimo: saída 1, sem token e sem instalar" \
  "$([ "$codigo" = 1 ] && grep -q 'não cabe para 3 instâncias' "$tmp/err" && [ "$(ncalls)" = 1 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"
limpar
codigo="$(MEMMAX=4096 rodar --vps root@v --repos dono/a,dono/b,dono/c --var MEM_MIN_MB=1024 --quieto)"
afirmar "com --var MEM_MIN_MB=1024 as três cabem, com 1280 MB cada" \
  "$([ "$codigo" = 0 ] && stdin_tem 2 'export MEMORY_MAX_MB=1280$' && stdin_tem 4 'export MEMORY_MAX_MB=1280$' && stdin_tem 2 'export MEM_MIN_MB=1024$' && echo 0 || echo 1)"
limpar
codigo="$(rodar --vps root@v --repos dono/a,dono/b --var MEMORY_MAX_MB=3000 --quieto)"
afirmar "com --var MEMORY_MAX_MB explícito: sem painel de cálculo, cada uma usa o valor dado" \
  "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 2 ] && stdin_tem 1 'export MEMORY_MAX_MB=3000$' && stdin_tem 2 'export MEMORY_MAX_MB=3000$' && echo 0 || echo 1)"
limpar
codigo="$(CABE=nao rodar --vps root@v --repos dono/a,dono/b --quieto)"
afirmar "servidor que não cabe: saída 1, mostra o veredito, sem token e sem instalar" \
  "$([ "$codigo" = 1 ] && grep -q 'VEREDITO: não cabe' "$tmp/out" "$tmp/err" && [ "$(ncalls)" = 1 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"

limpar
codigo="$(CABE=erro rodar --vps root@v --repos dono/a,dono/b --quieto)"
afirmar "painel que falha (não é 'não cabe'): saída 1, diz que o painel falhou, sem token e sem instalar" \
  "$([ "$codigo" = 1 ] && grep -q 'O painel falhou antes de dar o veredito' "$tmp/err" && ! grep -q 'não cabe' "$tmp/err" && [ "$(ncalls)" = 1 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"

limpar
codigo="$(FALHA_NOME=b rodar --vps root@v --repos dono/a,dono/b,dono/c --var MEM_MIN_MB=1024 --quieto)"
afirmar "falha no segundo: saída 1, diz onde falhou e quem já foi instalado, e não tenta o terceiro" \
  "$([ "$codigo" = 1 ] && grep -q 'falhou em dono/b' "$tmp/err" && grep -q 'instaladas: a' "$tmp/err" && grep -q 'não tentadas: c' "$tmp/err" && [ "$(ncalls)" = 3 ] && [ "$(gh_vezes registration-token)" = 2 ] && echo 0 || echo 1)"

limpar
codigo="$(rodar --local --repos dono/a,dono/b --quieto)"
afirmar "--local --repos instala as duas no shell local, sem ssh" \
  "$([ "$codigo" = 0 ] && [ "$(ncalls)" = 3 ] && tem 2 '^shell-local' && tem 3 '^shell-local' && echo 0 || echo 1)"

limpar
ruim() { # <descrição> <argumentos…>
  local d="$1"; shift
  limpar
  afirmar "$d: saída 2 e nada executado nem gerado" "$([ "$(rodar "$@")" = 2 ] && [ "$(ncalls)" = 0 ] && [ ! -e "$tmp/gh.log" ] && echo 0 || echo 1)"
}
ruim "--repos com --repo" --vps root@v --repos a/b,c/d --repo e/f
ruim "--repos com --org" --vps root@v --repos a/b,c/d --org o
ruim "--repos com --nome" --vps root@v --repos a/b,c/d --nome x
ruim "--repos com --remover" --vps root@v --repos a/b,c/d --remover
ruim "--repos com --status" --vps root@v --repos a/b,c/d --status
ruim "--repos com --so-checar" --vps root@v --repos a/b,c/d --so-checar
ruim "--repos com --mostrar" --vps root@v --repos a/b,c/d --mostrar
ruim "--repos com um item que não é dono/repo" --vps root@v --repos a/b,abc
ruim "--repos com item vazio" --vps root@v --repos a/b,,c/d
ruim "--repos com vírgula no fim" --vps root@v --repos a/b,c/d,
ruim "--repos com vírgula no começo" --vps root@v --repos ,a/b,c/d
ruim "--repos com nomes derivados repetidos (a/x e b/x)" --vps root@v --repos a/x,b/x
ruim "--repos com o mesmo repositório duas vezes" --vps root@v --repos a/x,a/x
ruim "--repos sem --vps nem --local" --repos a/b,c/d

afirmar "o registrar.sh não grava o token em arquivo nem o lê do teclado" "$(! grep -nE 'read .*(token|TOKEN)' "$script"; echo $?)"

if [ "$falhas" -eq 0 ]; then echo "local e lote: tudo certo ($oks ok)"; exit 0; fi
echo "local e lote: $falhas falha(s), $oks ok"; exit 1
