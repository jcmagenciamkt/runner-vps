#!/usr/bin/env bash
# Testes da instalação do instalar.sh (Task 3 do plano): usuário, Docker rootless, runner, limites, serviço,
# idempotência e extras. Tudo contra a VPS falsa.
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
tudo_saida() { cat "$TMP/out" "$TMP/err"; }
tem() { grep -qF -- "$2" "$1"; }                      # tem <arquivo> <texto>
chamou() { grep -qF -- "$1" "$TMP/chamadas.log"; }    # chamou <texto>
linha_de() { grep -nF -- "$1" "$TMP/chamadas.log" | tail -n 1 | cut -d: -f1; }
instalar_exemplo() { RUNNER_NOME=exemplo RUNNER_URL=$URL rodar; }
R() { printf '%s' "$TMP/raiz"; }
H() { printf '%s' "$TMP/raiz/opt/runner-vps/exemplo"; }

echo "instalar.sh: instalação completa"
nova_vps
RUNNER_ROTULOS=a,b ENV_EXTRAS='A=1;B=dois' HOSTS_EXTRAS='127.0.0.1 app.exemplo.test' RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo; codigo=$?
afirmar "instala com saída 0" test "$codigo" -eq 0
afirmar "mostra o veredito antes de instalar" tem "$TMP/out" "VEREDITO: cabe (MemoryMax=5120M CPUQuota=300%)"
afirmar "useradd chamado uma vez para runner-exemplo" test "$(chamadas useradd | grep -c 'runner-exemplo')" -eq 1
afirmar "useradd sem grupo docker nem sudo" bash -c '! grep -E "^useradd" "$1" | grep -qE "docker|sudo| -G|--groups"' _ "$TMP/chamadas.log"
afirmar "subuid e subgid com a faixa de 65536" \
  bash -c 'grep -qx "runner-exemplo:100000:65536" "$1/etc/subuid" && grep -qx "runner-exemplo:100000:65536" "$1/etc/subgid"' _ "$(R)"
afirmar "apt instala uidmap, dbus-user-session e slirp4netns" \
  bash -c 'grep -E "^apt " "$1" | grep -q "uidmap" && grep -E "^apt " "$1" | grep -q "dbus-user-session" && grep -E "^apt " "$1" | grep -q "slirp4netns"' _ "$TMP/chamadas.log"
afirmar "linger ligado" chamou "loginctl enable-linger runner-exemplo"
afirmar "rootless: check antes de install" test "$(linha_de 'rootless check')" -lt "$(linha_de 'rootless install')"
afirmar "docker do usuário habilitado e iniciado" chamou "--user -M runner-exemplo@ enable --now docker"
afirmar "runner baixado e extraído em \$HOME/runner" test -x "$(H)/runner/run.sh" -a -x "$(H)/runner/config.sh"
afirmar "installdependencies do runner executado" chamou "installdependencies"
afirmar "config.sh com os argumentos do design" \
  chamou "config.sh --unattended --replace --url $URL --name exemplo --labels a,b --work _work"
afirmar "o token chegou ao config.sh pelo ambiente" test "$(cat "$TMP/config-token-visto")" = "$TOKEN_FALSO"
afirmar_sem "$TMP/chamadas.log" "$TOKEN_FALSO"
afirmar_sem "$TMP/raiz" "$TOKEN_FALSO"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"
env_runner="$(H)/runner/.env"
afirmar ".env com DOCKER_HOST do usuário" tem "$env_runner" "DOCKER_HOST=unix:///run/user/2001/docker.sock"
afirmar ".env com PATH começando por \$HOME/.local/bin" grep -q '^PATH=/opt/runner-vps/exemplo/.local/bin:' "$env_runner"
afirmar ".env com o gancho de fim de job" tem "$env_runner" "ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/runner-vps/exemplo/bin/gancho-fim.sh"
afirmar ".env com as linhas de ENV_EXTRAS" bash -c 'grep -qx "A=1" "$1" && grep -qx "B=dois" "$1"' _ "$env_runner"
afirmar "gancho instalado e executável" test -x "$(H)/bin/gancho-fim.sh"
unit="$(H)/.config/systemd/user/runner-vps.service"
afirmar "unidade: ExecStart, Restart, After=docker.service, default.target" \
  bash -c 'grep -qx "ExecStart=/opt/runner-vps/exemplo/runner/run.sh" "$1" && grep -qx "Restart=always" "$1" && grep -qx "RestartSec=10" "$1" && grep -qx "After=docker.service" "$1" && grep -qx "WantedBy=default.target" "$1"' _ "$unit"
slice="$(R)/etc/systemd/system/user-2001.slice.d/runner-vps.conf"
afirmar "limites da fatia do usuário" \
  bash -c 'grep -qx "MemoryMax=5120M" "$1" && grep -qx "MemorySwapMax=0" "$1" && grep -qx "CPUQuota=300%" "$1" && grep -qx "TasksMax=4096" "$1"' _ "$slice"
afirmar "daemon-reload chamado" chamou "systemctl daemon-reload"
afirmar "runner-vps habilitado e iniciado (já registrado)" chamou "--user -M runner-exemplo@ enable --now runner-vps"
afirmar "dono dos arquivos acertado para o usuário" chamou "chown -R runner-exemplo:runner-exemplo"
afirmar "/etc/hosts com uma linha marcada" \
  test "$(grep -c '^127.0.0.1 app.exemplo.test # runner-vps exemplo$' "$(R)/etc/hosts")" -eq 1
afirmar "/etc/hosts mantém as linhas originais" grep -qx '127.0.0.1 localhost' "$(R)/etc/hosts"
afirmar ".conf com os valores" bash -c '. "$1"; [ "$RUNNER_ROTULOS" = a,b ] && [ "$MEMORY_MAX_MB" = 5120 ] && [ "$HOSTS_EXTRAS" = "127.0.0.1 app.exemplo.test" ]' _ "$(R)/etc/runner-vps/exemplo.conf"
afirmar "termina mostrando o estado" tem "$TMP/out" "serviço runner-vps: active"

echo "instalar.sh: DOCKER_ROOTLESS=0"
nova_vps
DOCKER_ROOTLESS=0 instalar_exemplo; codigo=$?
afirmar "sem rootless: saída 0" test "$codigo" -eq 0
afirmar "sem rootless: nenhuma chamada ao rootless" test -z "$(chamadas rootless)"
afirmar "sem rootless: .env sem DOCKER_HOST" bash -c '! grep -q DOCKER_HOST "$1"' _ "$(H)/runner/.env"
afirmar "sem rootless: unidade sem After=docker.service" bash -c '! grep -q "After=docker.service" "$1"' _ "$(H)/.config/systemd/user/runner-vps.service"
afirmar "sem rootless: subuid sem linha da instância" bash -c '! grep -q runner-exemplo "$1/etc/subuid"' _ "$(R)"
afirmar "sem rootless: docker não habilitado" bash -c '! grep -q "enable --now docker" "$1"' _ "$TMP/chamadas.log"
afirmar "sem rootless: apt sem uidmap" bash -c '! grep -E "^apt " "$1" | grep -q uidmap' _ "$TMP/chamadas.log"

echo "instalar.sh: o token e os caminhos de falha"
nova_vps
CONFIG_SAIDA=1 RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo; codigo=$?
afirmar "config.sh falhando: saída 1" test "$codigo" -eq 1
afirmar "config.sh falhando: mensagem fala do registro" bash -c 'tudo="$(cat "$1" "$2")"; case "$tudo" in *registro*) exit 0;; *) exit 1;; esac' _ "$TMP/out" "$TMP/err"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"
afirmar_sem "$TMP/raiz" "$TOKEN_FALSO"
afirmar_sem "$TMP/chamadas.log" "$TOKEN_FALSO"
afirmar "o script nunca liga set -x" bash -c '! grep -qE "^[[:space:]]*set -[a-z]*x|set -o xtrace" "$1"' _ "$script"

nova_vps
instalar_exemplo; codigo=$?
afirmar "sem token: saída 0" test "$codigo" -eq 0
afirmar "sem token: aviso de registro pulado" bash -c 'cat "$1" "$2" | grep -q "registro pulado"' _ "$TMP/out" "$TMP/err"
afirmar "sem token: config.sh não chamado" test -z "$(chamadas config.sh)"
afirmar "sem token: o resto foi feito (unidade, limites, .env)" \
  test -f "$(H)/.config/systemd/user/runner-vps.service" -a -f "$(R)/etc/systemd/system/user-2001.slice.d/runner-vps.conf" -a -f "$(H)/runner/.env"
afirmar "sem token e sem registro: serviço só habilitado, sem --now" \
  bash -c 'grep -qF "enable runner-vps" "$1" && ! grep -qF "enable --now runner-vps" "$1"' _ "$TMP/chamadas.log"

echo "instalar.sh: idempotência"
nova_vps
HOSTS_EXTRAS='127.0.0.1 app.exemplo.test' RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo
antes="$(snapshot "$TMP/raiz")"
: > "$TMP/chamadas.log"
sleep 0.02
RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "segunda execução: saída 0" test "$codigo" -eq 0
afirmar "segunda execução: nada alterado (conteúdo e mtime)" test "$antes" = "$(snapshot "$TMP/raiz")"
afirmar "segunda execução: nenhum restart" bash -c '! grep -q restart "$1"' _ "$TMP/chamadas.log"
afirmar "segunda execução: não recria o usuário nem rebaixa o runner" bash -c '! grep -qE "^(useradd|baixar|config.sh)" "$1"' _ "$TMP/chamadas.log"
afirmar "segunda execução: uma linha do usuário em subuid e subgid" \
  test "$(grep -c '^runner-exemplo:' "$TMP/raiz/etc/subuid")" -eq 1 -a "$(grep -c '^runner-exemplo:' "$TMP/raiz/etc/subgid")" -eq 1
afirmar "segunda execução: uma linha marcada em /etc/hosts" test "$(grep -c '# runner-vps exemplo$' "$TMP/raiz/etc/hosts")" -eq 1
afirmar "segunda execução: sem daemon-reload" bash -c '! grep -q "daemon-reload" "$1"' _ "$TMP/chamadas.log"

sleep 0.02
: > "$TMP/chamadas.log"
RUNNER_NOME=exemplo MEMORY_MAX_MB=4096 rodar; codigo=$?
depois="$(snapshot "$TMP/raiz")"
alterados="$(diff <(printf '%s\n' "$antes") <(printf '%s\n' "$depois") | sed -n 's/^> \(\S*\) .*/\1/p' | sort | tr '\n' ' ')"
afirmar "mudar MEMORY_MAX_MB: saída 0" test "$codigo" -eq 0
afirmar "mudar MEMORY_MAX_MB: só o .conf e o .slice.d mudam" \
  test "$alterados" = "./etc/runner-vps/exemplo.conf ./etc/systemd/system/user-2001.slice.d/runner-vps.conf "
afirmar "mudar MEMORY_MAX_MB: novo limite na fatia" grep -qx "MemoryMax=4096M" "$TMP/raiz/etc/systemd/system/user-2001.slice.d/runner-vps.conf"
afirmar "mudar MEMORY_MAX_MB: chama daemon-reload" chamou "systemctl daemon-reload"
afirmar "mudar MEMORY_MAX_MB: sem restart" bash -c '! grep -q restart "$1"' _ "$TMP/chamadas.log"

echo "instalar.sh: falhas que param antes do runner"
nova_vps
RUNNER_SHA256=0000000000000000000000000000000000000000000000000000000000000000 RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo; codigo=$?
afirmar "sha256 errado: saída 1" test "$codigo" -eq 1
afirmar "sha256 errado: nada extraído em \$HOME/runner" test ! -e "$(H)/runner"
afirmar "sha256 errado: a mensagem cita o sha256" bash -c 'cat "$1" "$2" | grep -q sha256' _ "$TMP/out" "$TMP/err"
afirmar "sha256 errado: config.sh não chamado" test -z "$(chamadas config.sh)"

nova_vps
cat > "$TMP/bin/rootless-ruim" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "rootless $*" >> "$TMP/chamadas.log"
[ "${1:-}" = check ] && { echo "faltam subuid" ; exit 1; }
exit 0
FALSO
chmod +x "$TMP/bin/rootless-ruim"
ROOTLESS_CMD="$TMP/bin/rootless-ruim" RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo; codigo=$?
afirmar "rootless check falhando: saída 1" test "$codigo" -eq 1
afirmar "rootless check falhando: para antes do runner" test ! -e "$(H)/runner"
afirmar "rootless check falhando: dá o motivo" bash -c 'cat "$1" "$2" | grep -q "faltam subuid"' _ "$TMP/out" "$TMP/err"
afirmar "rootless check falhando: não há fallback para o socket de root" bash -c '! grep -rq "/var/run/docker.sock" "$1"' _ "$TMP/raiz"
afirmar "rootless check falhando: install não chamado" bash -c '! grep -q "rootless install" "$1"' _ "$TMP/chamadas.log"

nova_vps
ROOTLESS_CMD="$TMP/bin/nao-existe" instalar_exemplo; codigo=$?
afirmar "setuptool ausente: apt recebe os pacotes do Docker" bash -c 'grep -E "^apt " "$1" | grep -q "docker-ce-rootless-extras"' _ "$TMP/chamadas.log"
afirmar "setuptool ausente mesmo após o apt: saída 1" test "$codigo" -eq 1

echo "instalar.sh: extras"
nova_vps
cat > "$TMP/extras.sh" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "extras executado" >> "$TMP/chamadas.log"
FALSO
HOSTS_EXTRAS='127.0.0.1 app.exemplo.test' PACOTES_EXTRAS='libfoo libbar' EXTRAS_SH="$TMP/extras.sh" RUNNER_TOKEN="$TOKEN_FALSO" instalar_exemplo; codigo=$?
afirmar "extras: saída 0" test "$codigo" -eq 0
afirmar "extras: PACOTES_EXTRAS chega ao apt" bash -c 'grep -E "^apt " "$1" | grep -q "libfoo libbar"' _ "$TMP/chamadas.log"
afirmar "extras: EXTRAS_SH local executado" chamou "extras executado"
afirmar "extras: EXTRAS_SH roda depois de ligar o serviço" \
  test "$(linha_de 'extras executado')" -gt "$(linha_de 'enable --now runner-vps')"
afirmar "extras: HOSTS_EXTRAS com a marca da instância" grep -qx '127.0.0.1 app.exemplo.test # runner-vps exemplo' "$TMP/raiz/etc/hosts"
# trocar o HOSTS_EXTRAS troca a linha, não acumula
RUNNER_NOME=exemplo HOSTS_EXTRAS='127.0.0.1 outro.exemplo.test' rodar
afirmar "extras: mudar HOSTS_EXTRAS troca a linha marcada" \
  test "$(grep -c '# runner-vps exemplo$' "$TMP/raiz/etc/hosts")" -eq 1 -a "$(grep -c outro.exemplo.test "$TMP/raiz/etc/hosts")" -eq 1

nova_vps
antes="$(snapshot "$TMP/raiz")"
EXTRAS_SH=https://exemplo.test/extras.sh instalar_exemplo; codigo=$?
afirmar "EXTRAS_SH por URL sem EXTRAS_SHA256: recusa com saída 2" test "$codigo" -eq 2
afirmar "EXTRAS_SH por URL sem EXTRAS_SHA256: nada criado" test "$antes" = "$(snapshot "$TMP/raiz")"

nova_vps
instalar_exemplo
sha_extras="$(sha256sum "$TMP/extras.sh" | cut -d' ' -f1)"
: > "$TMP/chamadas.log"
BAIXAR_ARQUIVO="$TMP/extras.sh" EXTRAS_SH=https://exemplo.test/extras.sh EXTRAS_SHA256="$sha_extras" RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "EXTRAS_SH por URL com sha256 certo: executa" bash -c '[ "$1" -eq 0 ] && grep -q "extras executado" "$2"' _ "$codigo" "$TMP/chamadas.log"
: > "$TMP/chamadas.log"
BAIXAR_ARQUIVO="$TMP/extras.sh" EXTRAS_SH=https://exemplo.test/extras.sh EXTRAS_SHA256=1111111111111111111111111111111111111111111111111111111111111111 RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "EXTRAS_SH por URL com sha256 errado: saída 1 e não executa" bash -c '[ "$1" -eq 1 ] && ! grep -q "extras executado" "$2"' _ "$codigo" "$TMP/chamadas.log"

echo "instalar.sh: duas instâncias na mesma VPS"
MEM_LIVRE_MB=16384 nova_vps
RUNNER_NOME=um RUNNER_URL=$URL MEMORY_MAX_MB=4096 rodar; c1=$?
RUNNER_NOME=dois RUNNER_URL=$URL rodar; c2=$?
afirmar "duas instâncias: ambas instalam" test "$c1" -eq 0 -a "$c2" -eq 0
afirmar "duas instâncias: usuários runner-um e runner-dois criados" \
  bash -c 'grep -q "runner-um" "$1" && grep -q "runner-dois" "$1"' _ "$TMP/chamadas.log"
afirmar "duas instâncias: HOMEs distintos" test -d "$TMP/raiz/opt/runner-vps/um/runner" -a -d "$TMP/raiz/opt/runner-vps/dois/runner"
afirmar "duas instâncias: .conf distintos" test -f "$TMP/raiz/etc/runner-vps/um.conf" -a -f "$TMP/raiz/etc/runner-vps/dois.conf"
afirmar "duas instâncias: fatias distintas (uid 2001 e 2002)" \
  test -f "$TMP/raiz/etc/systemd/system/user-2001.slice.d/runner-vps.conf" -a -f "$TMP/raiz/etc/systemd/system/user-2002.slice.d/runner-vps.conf"
afirmar "duas instâncias: a segunda desconta a memória da primeira (16384-1024-4096)" \
  grep -qx "MemoryMax=11264M" "$TMP/raiz/etc/systemd/system/user-2002.slice.d/runner-vps.conf"
afirmar "duas instâncias: faixas de subuid sem colisão" \
  bash -c 'grep -qx "runner-um:100000:65536" "$1/etc/subuid" && grep -qx "runner-dois:165536:65536" "$1/etc/subuid"' _ "$TMP/raiz"
afirmar "duas instâncias: faixas de subgid sem colisão" \
  bash -c 'grep -qx "runner-um:100000:65536" "$1/etc/subgid" && grep -qx "runner-dois:165536:65536" "$1/etc/subgid"' _ "$TMP/raiz"
afirmar "duas instâncias: DOCKER_HOST de cada uma com o seu uid" \
  bash -c 'grep -q "/run/user/2001/" "$1/opt/runner-vps/um/runner/.env" && grep -q "/run/user/2002/" "$1/opt/runner-vps/dois/runner/.env"' _ "$TMP/raiz"

relatorio "instalar.sh (instalação)"
