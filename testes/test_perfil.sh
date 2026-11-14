#!/usr/bin/env bash
# Testes do --perfil do registrar.sh (Task 16): um arquivo CHAVE=valor que vira argumentos, sem executar nada
# dele e sem aceitar token. Só usa --mostrar (não conecta, não chama o gh).
set -uo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../registrar.sh"
exemplo="$aqui/../exemplos/perfil-nativo.perfil"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

falhas=0; oks=0
afirmar() { if [ "$2" -eq 0 ]; then printf '  ok   %s\n' "$1"; oks=$((oks + 1)); else printf '  FALHA %s\n' "$1"; falhas=$((falhas + 1)); fi; }

printf '#!/usr/bin/env bash\necho SSH CHAMADO >> "%s/chamadas"\n' "$tmp" > "$tmp/ssh"
printf '#!/usr/bin/env bash\necho GH CHAMADO >> "%s/chamadas"\n' "$tmp" > "$tmp/gh"
chmod +x "$tmp/ssh" "$tmp/gh"
export SSH_CMD="$tmp/ssh" GH_CMD="$tmp/gh" HOME="$tmp/casa"; mkdir -p "$HOME"

perfil() { printf '%s\n' "$@" > "$tmp/p.perfil"; }
rodar() { bash "$script" "$@" > "$tmp/out" 2> "$tmp/err"; echo $?; }
saida_tem() { grep -qE -- "$1" "$tmp/out"; }

echo "--perfil"
perfil '# runner nativo, sem Docker' '' 'vps=root@vps.exemplo:2222' 'chave=~/chave-exemplo' 'repo=dono/repo' 'nome=exemplo' \
  'rotulos=self-hosted,linux,x64' 'sem-docker=1' 'var=MEMORY_MAX_MB=2048' 'var=CPU_QUOTA=150'
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "perfil completo com --mostrar: saída 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "vps, porta e chave do perfil (o ~/ vira o HOME)" "$(saida_tem "Comando: $tmp/ssh -i $HOME/chave-exemplo -p 2222 -o BatchMode=yes root@vps.exemplo bash -s --"; echo $?)"
afirmar "nome, URL do repositório e rótulos" "$(saida_tem 'export RUNNER_NOME=exemplo$' && saida_tem 'export RUNNER_URL=https://github.com/dono/repo$' && saida_tem 'export RUNNER_ROTULOS=self-hosted\\,linux\\,x64$'; echo $?)"
afirmar "sem-docker=1 vira DOCKER_ROOTLESS=0" "$(saida_tem 'export DOCKER_ROOTLESS=0$'; echo $?)"
afirmar "duas linhas var= viram duas variáveis" "$(saida_tem 'export MEMORY_MAX_MB=2048$' && saida_tem 'export CPU_QUOTA=150$'; echo $?)"
afirmar "o token continua redigido e nada foi chamado" "$(saida_tem 'RUNNER_TOKEN=<redigido>' && [ ! -e "$tmp/chamadas" ]; echo $?)"

codigo="$(rodar --perfil "$tmp/p.perfil" --nome outro --mostrar)"
afirmar "argumento da linha de comando vence o perfil (--nome outro)" "$([ "$codigo" = 0 ] && saida_tem 'export RUNNER_NOME=outro$' && ! saida_tem 'RUNNER_NOME=exemplo'; echo $?)"
codigo="$(rodar --mostrar --perfil "$tmp/p.perfil")"
afirmar "a posição do --perfil na linha não importa" "$([ "$codigo" = 0 ] && saida_tem 'export RUNNER_NOME=exemplo$'; echo $?)"

perfil 'local=1' 'repo=dono/repo' 'nome=exemplo'
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "local=1: mostra o shell local, sem ssh" "$([ "$codigo" = 0 ] && saida_tem 'Comando: .*bash -s --' && ! saida_tem 'BatchMode'; echo $?)"

perfil 'vps=root@vps.exemplo' 'repo=dono/repo' 'nome=exemplo' 'valor=com espaços e # cerquilha'
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "chave desconhecida: saída 2 e diz qual" "$([ "$codigo" = 2 ] && grep -q 'valor' "$tmp/err"; echo $?)"

perfil 'vps=root@vps.exemplo' 'repo=dono/repo' 'nome=exemplo' 'var=RUNNER_TOKEN=SEGREDO123'
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "var=RUNNER_TOKEN: saída 2, mensagem do perfil e o valor não aparece" "$([ "$codigo" = 2 ] && grep -q 'o token não vai no perfil' "$tmp/err" && ! grep -q SEGREDO123 "$tmp/out" "$tmp/err"; echo $?)"
perfil 'vps=root@vps.exemplo' 'repo=dono/repo' 'nome=exemplo' 'token=SEGREDO123'
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "token=: saída 2, diz que o token não vai no perfil e o valor não aparece" "$([ "$codigo" = 2 ] && grep -q 'o token não vai no perfil' "$tmp/err" && ! grep -q SEGREDO123 "$tmp/out" "$tmp/err"; echo $?)"

perfil 'vps' 'repo=dono/repo'
afirmar "linha sem '=': saída 2" "$([ "$(rodar --perfil "$tmp/p.perfil" --mostrar)" = 2 ] && echo 0 || echo 1)"
perfil 'vps=root@vps.exemplo' 'repo=dono/repo' 'nome=exemplo' 'sem-docker=2'
afirmar "sem-docker=2 (só 1 vale): saída 2" "$([ "$(rodar --perfil "$tmp/p.perfil" --mostrar)" = 2 ] && echo 0 || echo 1)"
perfil 'vps=root@vps.exemplo' 'repo=dono/repo' 'nome=exemplo' 'local=0'
afirmar "local=0 (só 1 vale): saída 2" "$([ "$(rodar --perfil "$tmp/p.perfil" --mostrar)" = 2 ] && echo 0 || echo 1)"
afirmar "arquivo inexistente: saída 2" "$([ "$(rodar --perfil "$tmp/nao-existe" --mostrar)" = 2 ] && echo 0 || echo 1)"
afirmar "--perfil sem argumento: saída 2" "$([ "$(rodar --perfil)" = 2 ] && echo 0 || echo 1)"
perfil 'vps=root@vps.exemplo' 'perfil=outro.perfil' 'repo=dono/repo' 'nome=exemplo'
afirmar "perfil dentro de perfil não é aceito: saída 2" "$([ "$(rodar --perfil "$tmp/p.perfil" --mostrar)" = 2 ] && echo 0 || echo 1)"

# nada do arquivo é executado nem expandido
perfil 'vps=root@vps.exemplo' 'repo=dono/repo' "nome=exemplo" "rotulos=\$(touch $tmp/executou),\`touch $tmp/executou2\`,\$HOME"
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "valores com \$(…), crase e \$HOME não são executados nem expandidos" \
  "$([ ! -e "$tmp/executou" ] && [ ! -e "$tmp/executou2" ] && saida_tem 'RUNNER_ROTULOS=.*HOME' && [ "$codigo" = 0 ]; echo $?)"

# CRLF (arquivo editado no Windows) e espaços nas pontas da linha
printf 'vps=root@vps.exemplo\r\nrepo=dono/repo\r\nnome=exemplo\r\n' > "$tmp/p.perfil"
codigo="$(rodar --perfil "$tmp/p.perfil" --mostrar)"
afirmar "arquivo com CRLF funciona" "$([ "$codigo" = 0 ] && saida_tem 'export RUNNER_NOME=exemplo$'; echo $?)"

# o exemplo do repositório só usa chaves que o parser aceita e não traz dado real
afirmar "o exemplo existe" "$([ -r "$exemplo" ] && echo 0 || echo 1)"
conhecidas='vps|chave|local|repo|org|repos|nome|nome-github|rotulos|sem-docker|var'
ruins="$(grep -vE '^[[:space:]]*(#.*)?$' "$exemplo" | grep -vcE "^($conhecidas)=")"
afirmar "o exemplo só usa chaves conhecidas" "$([ "$ruins" = 0 ] && echo 0 || echo 1)"
afirmar "o exemplo usa só marcadores (<…>) e 127.0.0.1, sem IP real" "$(! grep -E '[0-9]{1,3}(\.[0-9]{1,3}){3}' "$exemplo" | grep -v '127\.0\.0\.1' | grep -q .; echo $?)"

if [ "$falhas" -eq 0 ]; then echo "perfil: tudo certo ($oks ok)"; exit 0; fi
echo "perfil: $falhas falha(s), $oks ok"; exit 1
