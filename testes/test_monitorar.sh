#!/usr/bin/env bash
# Testes de --monitorar / --monitorar-remover do instalar.sh e do script diário que ele instala (Task 18):
# CSV de métricas do VPS e do Runner.Listener, contra a VPS falsa.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
URL=https://github.com/dono/repo
saida_tem() { grep -qF -- "$1" "$TMP/out"; }
monitorar() { env -u RUNNER_NOME bash "$script" --monitorar "$@" > "$TMP/out" 2> "$TMP/err"; }
instalar() { # <nome>
  env RUNNER_NOME="$1" RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" MEMORY_MAX_MB=1024 MEM_MIN_MB=512 bash "$script" > "$TMP/out" 2> "$TMP/err"
}
SCRIPT_MON="$TMP/raiz/etc/runner-vps/monitor.sh"
CSV="$TMP/raiz/var/log/runner-vps-diario.csv"
UNID="$TMP/raiz/etc/systemd/system"
LR="$TMP/raiz/etc/logrotate.d/runner-vps-diario"
modo() { stat -c %a "$1"; }
# todos <condição…>: cada argumento é um comando (avaliado com eval); ok só se todos saírem com 0.
todos() { local c; for c in "$@"; do eval "$c" || return 1; done; }

echo "instalar.sh --monitorar"
MEM_LIVRE_MB=16384 nova_vps
env -u RUNNER_NOME bash "$script" --monitorar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem RUNNER_NOME: saída 0" test "$codigo" -eq 0
afirmar "script diário em /etc/runner-vps, 755" test -x "$SCRIPT_MON" -a "$(modo "$SCRIPT_MON")" = 755
afirmar "serviço oneshot que roda o script" bash -c 'grep -q "^Type=oneshot" "$1" && grep -q "^ExecStart=/etc/runner-vps/monitor.sh$" "$1"' _ "$UNID/runner-vps-monitor.service"
afirmar "timer diário, às 03:00, com Persistent" bash -c 'grep -q "^OnCalendar=\*-\*-\* 03:00:00$" "$1" && grep -q "^Persistent=true$" "$1" && grep -q "^WantedBy=timers.target" "$1"' _ "$UNID/runner-vps-monitor.timer"
afirmar "CSV existe, vazio, com 640" test -e "$CSV" -a ! -s "$CSV" -a "$(modo "$CSV")" = 640
afirmar "CSV entregue a root:root" bash -c 'grep -qE "^chown root:root .*runner-vps-diario.csv$" "$1"' _ "$TMP/chamadas.log"
afirmar "logrotate com tamanho máximo, rotação, compressão e create 640 root root" \
  bash -c 'grep -q "/var/log/runner-vps-diario.csv" "$1" && grep -q "maxsize" "$1" && grep -q "rotate" "$1" && grep -q "compress" "$1" && grep -q "create 640 root root" "$1"' _ "$LR"
afirmar "daemon-reload e timer habilitado" bash -c 'grep -q "systemctl daemon-reload" "$1" && grep -q "systemctl enable --now runner-vps-monitor.timer" "$1"' _ "$TMP/chamadas.log"
afirmar "diz onde está o CSV e como rodar uma vez" test "$(grep -c -E 'runner-vps-diario.csv|monitor.sh' "$TMP/out")" -ge 2
afirmar "explica VPS inteiro x Runner.Listener" test "$(grep -c -E 'vps_|listener_' "$TMP/out")" -ge 2
afirmar "o script não contém token" bash -c '! grep -q -E "RUNNER_TOKEN|$2" "$1"' _ "$SCRIPT_MON" "$TOKEN_FALSO"

: > "$TMP/chamadas.log"; antes="$(snapshot "$TMP/raiz")"
printf 'linha-que-ja-existia\n' >> "$CSV"; antes="$(snapshot "$TMP/raiz")"
monitorar; codigo=$?
afirmar "segunda vez: saída 0 e nenhum arquivo mudou (o CSV não é tocado)" test "$codigo" -eq 0 -a "$antes" = "$(snapshot "$TMP/raiz")"
afirmar "segunda vez: sem daemon-reload" bash -c '! grep -q "daemon-reload" "$1"' _ "$TMP/chamadas.log"
afirmar "o CSV mantém o conteúdo" test "$(cat "$CSV")" = linha-que-ja-existia

MONITOR_HORA=02:30 monitorar; codigo=$?
afirmar "MONITOR_HORA=02:30 muda o horário do timer" todos 'test "$codigo" -eq 0' "grep -q '^OnCalendar=\\*-\\*-\\* 02:30:00\$' \"$UNID/runner-vps-monitor.timer\""
antes="$(snapshot "$TMP/raiz")"
for h in 25:00 2:30 abc 02:60 ''; do
  MONITOR_HORA="$h" monitorar; codigo=$?
  afirmar "MONITOR_HORA='$h' inválido: saída 2" test "$codigo" -eq 2
done
afirmar "hora inválida não muda nada" test "$antes" = "$(snapshot "$TMP/raiz")"
RUNNER_NOME=Invalido bash "$script" --monitorar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "RUNNER_NOME informado e inválido continua recusado (saída 2)" test "$codigo" -eq 2

echo "instalar.sh --monitorar-remover"
: > "$TMP/chamadas.log"
env -u RUNNER_NOME bash "$script" --monitorar-remover > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "saída 0" test "$codigo" -eq 0
afirmar "timer desabilitado" bash -c 'grep -q "systemctl disable --now runner-vps-monitor.timer" "$1"' _ "$TMP/chamadas.log"
afirmar "script, unidades e logrotate removidos" bash -c 'for f in "$@"; do [ ! -e "$f" ] || exit 1; done' _ "$SCRIPT_MON" "$UNID/runner-vps-monitor.service" "$UNID/runner-vps-monitor.timer" "$LR"
afirmar "o CSV fica (e a saída diz isso)" todos 'test "$(cat "$CSV")" = linha-que-ja-existia' "saida_tem 'runner-vps-diario.csv'"
: > "$TMP/chamadas.log"
env -u RUNNER_NOME bash "$script" --monitorar-remover > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "de novo, sem nada instalado: saída 0 e nenhum comando com efeito" todos 'test "$codigo" -eq 0' "! grep -qE 'systemctl|daemon-reload' \"$TMP/chamadas.log\""

echo "script diário: uma linha por instância"
# comandos de leitura falsos
cat > "$TMP/bin/pgrep-listener" <<'F'
#!/usr/bin/env bash
# pgrep -u <usuario> -f Runner.Listener: imprime o pid de $TMP/listeners ("usuario pid")
while [ "$#" -gt 0 ]; do case "$1" in -u) usuario="$2"; shift ;; esac; shift; done
awk -v u="$usuario" '$1 == u { print $2; achou = 1 } END { exit !achou }' "$TMP/listeners" 2> /dev/null
F
cat > "$TMP/bin/ps-falso" <<'F'
#!/usr/bin/env bash
tudo="$*"
case "$tudo" in
  "-o pcpu=,rss= -p 4321") echo "  1.5 51200" ;;
  "-o pcpu=,rss= -p 5555") echo "  0.2 20480" ;;
  "-eo pid=,ppid=") printf '  4321     1\n  4400  4321\n  4401  4400\n  4402  4400\n  9999     1\n  5555     1\n' ;;
  "-u runner-exemplo -o pid=") printf '4321\n4400\n4401\n4402\n' ;;
  "-u runner-exemplo -o rss=") printf '51200\n102400\n20480\n20480\n' ;;
  "-u runner-beta -o pid=") printf '5555\n' ;;
  "-u runner-beta -o rss=") printf '20480\n' ;;
  *) exit 1 ;;
esac
F
cat > "$TMP/bin/df-monitor" <<'F'
#!/usr/bin/env bash
printf '  Used  Size Use%%\n12000M 40000M  30%%\n'
F
printf '#!/usr/bin/env bash\necho vps-exemplo\n' > "$TMP/bin/hostname-falso"
# sleep falso: troca o /proc/stat pela segunda amostra (a diferença dá 15,0% de CPU)
cat > "$TMP/bin/sleep-falso" <<'F'
#!/usr/bin/env bash
printf 'cpu 1100 0 550 8800 550 0 0 0 0 0\n' > "$RAIZ/proc/stat"
F
printf '#!/usr/bin/env bash\ncase " $* " in *" is-active "*) echo inactive; exit 3 ;; esac\nexit 0\n' > "$TMP/bin/systemctl-inativo"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/systemctl-mudo"
chmod +x "$TMP/bin/pgrep-listener" "$TMP/bin/ps-falso" "$TMP/bin/df-monitor" "$TMP/bin/hostname-falso" "$TMP/bin/sleep-falso" "$TMP/bin/systemctl-inativo" "$TMP/bin/systemctl-mudo"

# cenario: VPS com as instâncias "exemplo" e "beta" instaladas, o monitoramento instalado e os /proc falsos.
cenario() {
  MEM_LIVRE_MB=6144 nova_vps
  instalar exemplo; instalar beta
  env -u RUNNER_NOME bash "$script" --monitorar > /dev/null 2>&1
  printf 'cpu 1000 0 500 8000 500 0 0 0 0 0\n' > "$TMP/raiz/proc/stat"
  printf '93784.12 400000.00\n' > "$TMP/raiz/proc/uptime"
  printf 'runner-exemplo 4321\nrunner-beta 5555\n' > "$TMP/listeners"
  : > "$TMP/chamadas.log"
}
# roda o script diário com tudo falso (cada variável tem o padrão: o comando real)
diario() {
  env PGREP_CMD="$TMP/bin/pgrep-listener" PS_CMD="$TMP/bin/ps-falso" DF_CMD="$TMP/bin/df-monitor" HOSTNAME_CMD="$TMP/bin/hostname-falso" \
    SLEEP_CMD="$TMP/bin/sleep-falso" MONITOR_AGORA=2026-11-14T03:00:00-03:00 RUNNER_TOKEN="$TOKEN_FALSO" "$@" bash "$SCRIPT_MON" > "$TMP/out" 2> "$TMP/err"
}
# campo <instância> <coluna> [linha]: o valor da coluna na última linha daquela instância
campo() {
  awk -F, -v inst="$1" -v col="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == col) c = i; next } $3 == inst { v = $c } END { print v }' "$CSV"
}

cenario
diario; codigo=$?
afirmar "saída 0" test "$codigo" -eq 0
afirmar "cabeçalho na primeira linha, uma linha por instância (3 linhas)" test "$(wc -l < "$CSV")" -eq 3 -a "$(head -n 1 "$CSV")" = "data_hora,hostname,instancia,servico,ultimo_estado_conhecido,uptime_s,carga_1m,carga_5m,carga_15m,vps_cpu_pct,vps_mem_usada_mb,vps_mem_disp_mb,vps_mem_total_mb,vps_disco_usado_mb,vps_disco_total_mb,vps_disco_usado_pct,runner_procs,runner_filhos,runner_mem_total_mb,listener_pid,listener_cpu_pct,listener_mem_mb"
afirmar "todas as linhas têm 22 campos" test "$(awk -F, 'NF != 22' "$CSV" | wc -l)" -eq 0
afirmar "data, hostname e instância" test "$(campo exemplo data_hora)" = 2026-11-14T03:00:00-03:00 -a "$(campo exemplo hostname)" = vps-exemplo
afirmar "serviço e último estado conhecido" test "$(campo exemplo servico)" = active -a "$(campo exemplo ultimo_estado_conhecido)" = active
afirmar "uptime em segundos e carga média" test "$(campo exemplo uptime_s)" = 93784 -a "$(campo exemplo carga_1m)" = 0.10 -a "$(campo exemplo carga_5m)" = 0.20 -a "$(campo exemplo carga_15m)" = 0.30
afirmar "CPU total do VPS em 1 s de amostragem (15,0%)" test "$(campo exemplo vps_cpu_pct)" = 15.0
afirmar "memória do VPS: usada 2048, disponível 6144, total 8192" test "$(campo exemplo vps_mem_usada_mb)" = 2048 -a "$(campo exemplo vps_mem_disp_mb)" = 6144 -a "$(campo exemplo vps_mem_total_mb)" = 8192
afirmar "disco do VPS: 12000 de 40000 MB, 30%" test "$(campo exemplo vps_disco_usado_mb)" = 12000 -a "$(campo exemplo vps_disco_total_mb)" = 40000 -a "$(campo exemplo vps_disco_usado_pct)" = 30
afirmar "processos do usuário da instância: 4, filhos do listener: 3, memória total 190 MB" test "$(campo exemplo runner_procs)" = 4 -a "$(campo exemplo runner_filhos)" = 3 -a "$(campo exemplo runner_mem_total_mb)" = 190
afirmar "Runner.Listener: pid, CPU e memória (50 MB)" test "$(campo exemplo listener_pid)" = 4321 -a "$(campo exemplo listener_cpu_pct)" = 1.5 -a "$(campo exemplo listener_mem_mb)" = 50
afirmar "a outra instância tem os seus próprios números (1 processo, 0 filhos, 20 MB)" test "$(campo beta runner_procs)" = 1 -a "$(campo beta runner_filhos)" = 0 -a "$(campo beta listener_mem_mb)" = 20 -a "$(campo beta listener_pid)" = 5555
afirmar "CSV com 640" test "$(modo "$CSV")" = 640
afirmar "o token do ambiente não vai para o CSV nem para a saída" bash -c '! grep -q "$2" "$1" "$3" "$4"' _ "$CSV" "$TOKEN_FALSO" "$TMP/out" "$TMP/err"

diario; codigo=$?
afirmar "segunda execução: acrescenta duas linhas e não repete o cabeçalho" test "$codigo" -eq 0 -a "$(wc -l < "$CSV")" -eq 5 -a "$(grep -c '^data_hora' "$CSV")" -eq 1
afirmar "o script só escreve no CSV (nenhum comando com efeito no sistema)" bash -c '! grep -qE "systemctl .*(start|stop|restart|enable|disable|daemon-reload)|useradd|userdel|chown|loginctl" "$1"' _ "$TMP/chamadas.log"

echo "script diário: o runner fora do ar não derruba o registro"
cenario; : > "$TMP/listeners"
diario; codigo=$?
afirmar "sem Runner.Listener: saída 0 e linha gravada" test "$codigo" -eq 0 -a "$(wc -l < "$CSV")" -eq 3
afirmar "listener_pid, listener_cpu_pct e listener_mem_mb ficam UNKNOWN" test "$(campo exemplo listener_pid)" = UNKNOWN -a "$(campo exemplo listener_cpu_pct)" = UNKNOWN -a "$(campo exemplo listener_mem_mb)" = UNKNOWN
afirmar "as métricas do VPS continuam" test "$(campo exemplo vps_cpu_pct)" = 15.0 -a "$(campo exemplo vps_mem_total_mb)" = 8192
cenario; diario SYSTEMCTL_CMD="$TMP/bin/systemctl-inativo"
afirmar "serviço parado: servico=inactive e o último estado conhecido também" test "$(campo exemplo servico)" = inactive -a "$(campo exemplo ultimo_estado_conhecido)" = inactive
cenario; diario > /dev/null; diario SYSTEMCTL_CMD="$TMP/bin/systemctl-mudo"
afirmar "systemctl sem resposta: servico=UNKNOWN, mas o último estado conhecido continua o da execução anterior (active)" test "$(campo exemplo servico)" = UNKNOWN -a "$(campo exemplo ultimo_estado_conhecido)" = active
cenario; diario SYSTEMCTL_CMD="$TMP/bin/systemctl-mudo"
afirmar "systemctl sem resposta e sem histórico: último estado UNKNOWN" test "$(campo exemplo servico)" = UNKNOWN -a "$(campo exemplo ultimo_estado_conhecido)" = UNKNOWN
cenario; rm -f "$TMP/usuarios/runner-beta"
diario; codigo=$?
afirmar "usuário da instância que não existe mais: servico=UNKNOWN e a outra instância segue normal" test "$codigo" -eq 0 -a "$(campo beta servico)" = UNKNOWN -a "$(campo exemplo servico)" = active

echo "script diário: sem instâncias, e arquivos"
MEM_LIVRE_MB=6144 nova_vps
env -u RUNNER_NOME bash "$script" --monitorar > /dev/null 2>&1
printf 'cpu 1000 0 500 8000 500 0 0 0 0 0\n' > "$TMP/raiz/proc/stat"; printf '10.0 5.0\n' > "$TMP/raiz/proc/uptime"; : > "$TMP/listeners"
diario; codigo=$?
afirmar "sem instâncias: uma linha com instancia '-' e métricas do VPS" test "$codigo" -eq 0 -a "$(wc -l < "$CSV")" -eq 2 -a "$(campo - vps_mem_total_mb)" = 8192 -a "$(campo - servico)" = UNKNOWN -a "$(campo - listener_pid)" = UNKNOWN
cenario
chmod 666 "$CSV"; diario
afirmar "o script volta o CSV para 640 se alguém mudou as permissões" test "$(modo "$CSV")" = 640
cenario; rm -f "$TMP/raiz/proc/uptime" "$TMP/raiz/proc/loadavg"
diario; codigo=$?
afirmar "uptime e carga ilegíveis: UNKNOWN, sem derrubar o registro" test "$codigo" -eq 0 -a "$(campo exemplo uptime_s)" = UNKNOWN -a "$(campo exemplo carga_1m)" = UNKNOWN
cenario; rm -rf "$TMP/raiz/var/log"; printf 'x' > "$TMP/raiz/var/log"
diario; codigo=$?
afirmar "CSV impossível de gravar: saída 1 (o systemd mostra a falha)" test "$codigo" -eq 1

cenario; rm -f "$CSV"; mkdir "$CSV"
diario; codigo=$?
afirmar "CSV que não aceita acréscimo (já 'tem conteúdo'): saída 1" test "$codigo" -eq 1

relatorio "instalar.sh (monitorar)"
