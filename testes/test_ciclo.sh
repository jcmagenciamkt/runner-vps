#!/usr/bin/env bash
# Testes da janela de horário (JANELA) e da validade (VALIDADE) do instalar.sh (Task 14 do plano): timers do
# systemd, script de ciclo (root, fora do HOME do runner), reaplicação, limpeza e remoção. VPS falsa.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
URL=https://github.com/dono/repo
HOJE=2026-11-14

# pgrep e sleep falsos: $TMP/ocupado = quantas consultas ainda dizem "ocupado" (ou "sempre"); sleep só registra.
cat > "$TMP/bin/pgrep-falso" <<'FALSO'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >> "$TMP/chamadas.log"
f="$TMP/ocupado"; v="$(cat "$f" 2> /dev/null || echo 0)"
if [ "$v" = sempre ]; then exit 0; fi
if [ "$v" -gt 0 ]; then echo $((v - 1)) > "$f"; exit 0; fi
exit 1
FALSO
printf '#!/usr/bin/env bash\nprintf "sleep %%s\\n" "$*" >> "$TMP/chamadas.log"\n' > "$TMP/bin/sleep-falso"
chmod +x "$TMP/bin/pgrep-falso" "$TMP/bin/sleep-falso"
export PGREP_CMD="$TMP/bin/pgrep-falso" SLEEP_CMD="$TMP/bin/sleep-falso"

# instalar [VAR=valor…]: instala (ou reaplica) a instância "exemplo"; CICLO_AGORA vale 23:00 se não for definido.
instalar() {
  env RUNNER_NOME=exemplo RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" CICLO_HOJE=$HOJE CICLO_AGORA="${CICLO_AGORA:-23:00}" "$@" \
    bash "$script" > "$TMP/out" 2> "$TMP/err"
}
reaplicar() { # sem token
  env RUNNER_NOME=exemplo CICLO_HOJE=$HOJE CICLO_AGORA="${CICLO_AGORA:-23:00}" "$@" bash "$script" > "$TMP/out" 2> "$TMP/err"
}
ciclo() { # <subcomando>: roda o script de ciclo gravado, como o systemd faria
  : > "$TMP/chamadas.log"
  env CICLO_HOJE="${CICLO_HOJE:-$HOJE}" CICLO_AGORA="${CICLO_AGORA:-23:00}" bash "$RAIZ/etc/runner-vps/ciclo-exemplo.sh" "$@" > "$TMP/out" 2> "$TMP/err"
}
chamou() { grep -qxF -- "$1" "$TMP/chamadas.log"; }
chamou_algo() { grep -qE -- "$1" "$TMP/chamadas.log"; }
U='systemctl --user -M runner-exemplo@'   # prefixo das chamadas ao serviço do usuário
CIC='etc/runner-vps/ciclo-exemplo.sh'
UNID='etc/systemd/system'

echo "janela e validade: sem nada configurado"
nova_vps
instalar; codigo=$?
afirmar "instala (saída 0)" test "$codigo" -eq 0
afirmar "sem JANELA nem VALIDADE: nenhum script nem unidade de ciclo" \
  test ! -e "$RAIZ/$CIC" -a "$(ls "$RAIZ/$UNID" | grep -c 'runner-vps-exemplo')" -eq 0
afirmar "o serviço do runner é habilitado e iniciado como sempre" chamou "$U enable --now runner-vps"
afirmar "nenhum timer foi tocado" test "$(grep -c 'timer' "$TMP/chamadas.log")" -eq 0

echo "janela: arquivos e chamadas (dentro da janela)"
nova_vps
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00; codigo=$?
afirmar "instala com JANELA (saída 0)" test "$codigo" -eq 0
afirmar "o script de ciclo existe, é executável e fica em /etc/runner-vps (fora do HOME do runner)" \
  test -x "$RAIZ/$CIC" -a "$(stat -c %a "$RAIZ/$CIC")" = 755
afirmar "o script não está dentro do HOME do runner (que o próprio usuário pode editar)" \
  test -z "$(find "$RAIZ/opt" -name 'ciclo-*' 2> /dev/null)"
afirmar "o timer tem os horários de início e fim e o disparo na inicialização" "$( bash -c 'grep -qxF "OnCalendar=*-*-* 22:00:00" "$1" && grep -qxF "OnCalendar=*-*-* 06:00:00" "$1" && grep -qxF "OnBootSec=1min" "$1" && grep -q "WantedBy=timers.target" "$1"' _ "$RAIZ/$UNID/runner-vps-exemplo-janela.timer"; echo $?)"
afirmar "o serviço do timer chama o script com 'ajustar' pelo caminho real e dá tempo para esperar o job" "$( bash -c 'grep -qxF "ExecStart=/etc/runner-vps/ciclo-exemplo.sh ajustar" "$1" && grep -q "^TimeoutStartSec=[0-9]*" "$1" && grep -qxF "Type=oneshot" "$1"' _ "$RAIZ/$UNID/runner-vps-exemplo-janela.service"; echo $?)"
afirmar "sem VALIDADE: nenhuma unidade de validade" test ! -e "$RAIZ/$UNID/runner-vps-exemplo-validade.timer"
afirmar "o serviço do usuário NÃO é habilitado na inicialização (o timer o controla)" \
  chamou "$U disable runner-vps"
afirmar "o serviço do usuário não é habilitado nem iniciado pelo instalador (nada de 'enable --now runner-vps')" \
  bash -c '! grep -q "enable --now runner-vps\$" "$1"' _ "$TMP/chamadas.log"
afirmar "daemon-reload e o timer habilitado e iniciado" chamou_algo '^systemctl enable --now runner-vps-exemplo-janela.timer$'
afirmar "dentro da janela (23:00): o runner é iniciado" chamou "$U start runner-vps"
afirmar "o log do instalador diz a janela" grep -q '22:00-06:00' "$TMP/out"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar "o script não contém token" bash -c '! grep -q "$2" "$1"' _ "$RAIZ/$CIC" "$TOKEN_FALSO"
afirmar "a janela fica gravada na configuração" grep -q '^JANELA=22:00-06:00$' "$RAIZ/etc/runner-vps/exemplo.conf"

echo "janela: fora do horário, o runner é parado"
nova_vps
CICLO_AGORA=12:00 instalar JANELA=22:00-06:00
afirmar "fora da janela (12:00): o runner é parado e não iniciado" "$( bash -c 'grep -qxF "$2 stop runner-vps" "$1" && ! grep -qF "$2 start runner-vps" "$1"' _ "$TMP/chamadas.log" "$U"; echo $?)"

echo "janela: o script de ciclo (horários)"
# casos: janela hora → inicia(1) ou para(0)
verifica() { # <janela> <hora> <esperado: start|stop>
  nova_vps
  CICLO_AGORA=23:00 instalar JANELA="$1"
  CICLO_AGORA="$2" ciclo ajustar
  if [ "$3" = start ]; then
    afirmar "janela $1 às $2: inicia" bash -c 'grep -qxF "$2 start runner-vps" "$1" && ! grep -qF "$2 stop runner-vps" "$1"' _ "$TMP/chamadas.log" "$U"
  else
    afirmar "janela $1 às $2: para" bash -c 'grep -qxF "$2 stop runner-vps" "$1" && ! grep -qF "$2 start runner-vps" "$1"' _ "$TMP/chamadas.log" "$U"
  fi
}
verifica 22:00-06:00 22:00 start
verifica 22:00-06:00 23:59 start
verifica 22:00-06:00 00:00 start
verifica 22:00-06:00 05:59 start
verifica 22:00-06:00 06:00 stop
verifica 22:00-06:00 12:00 stop
verifica 22:00-06:00 21:59 stop
verifica 08:00-18:00 08:00 start
verifica 08:00-18:00 17:59 start
verifica 08:00-18:00 18:00 stop
verifica 08:00-18:00 07:59 stop
verifica 08:00-18:00 23:00 stop

echo "janela: esperar o job terminar antes de parar"
nova_vps
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00
echo 3 > "$TMP/ocupado"
CICLO_AGORA=07:00 ciclo ajustar
afirmar "com job rodando: consulta o Runner.Worker do usuário do runner" chamou_algo '^pgrep -u runner-exemplo -f Runner.Worker$'
afirmar "espera em passos de 30 s enquanto houver job (3 esperas)" test "$(grep -c '^sleep 30$' "$TMP/chamadas.log")" -eq 3
afirmar "só para depois da última espera" \
  test "$(grep -n '^sleep 30$' "$TMP/chamadas.log" | tail -n 1 | cut -d: -f1)" -lt "$(grep -nF "$U stop runner-vps" "$TMP/chamadas.log" | cut -d: -f1)"
echo sempre > "$TMP/ocupado"
nova_vps; echo sempre > "$TMP/ocupado"
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00 JANELA_ESPERA_MIN=1
CICLO_AGORA=07:00 ciclo ajustar
afirmar "job que não termina: espera no máximo JANELA_ESPERA_MIN (1 min = 2 esperas) e para mesmo assim" "$(test "$(grep -c '^sleep 30$' "$TMP/chamadas.log")" -eq 2 && chamou "$U stop runner-vps"; echo $?)"
rm -f "$TMP/ocupado"
nova_vps
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00
CICLO_AGORA=23:30 ciclo ajustar
afirmar "dentro da janela não espera nem consulta o job" test "$(grep -c 'pgrep\|sleep' "$TMP/chamadas.log")" -eq 0

echo "validade"
nova_vps
instalar VALIDADE=2026-12-31; codigo=$?
afirmar "instala com VALIDADE (saída 0)" test "$codigo" -eq 0
afirmar "o timer de validade dispara no fim do dia, com Persistent" "$( bash -c 'grep -qxF "OnCalendar=2026-12-31 23:59:00" "$1" && grep -qxF "Persistent=true" "$1"' _ "$RAIZ/$UNID/runner-vps-exemplo-validade.timer"; echo $?)"
afirmar "o serviço de validade chama 'expirar'" grep -qxF 'ExecStart=/etc/runner-vps/ciclo-exemplo.sh expirar' "$RAIZ/$UNID/runner-vps-exemplo-validade.service"
afirmar "só validade: não há unidade de janela e o runner é habilitado e iniciado como sempre" "$(test ! -e "$RAIZ/$UNID/runner-vps-exemplo-janela.timer" && chamou "$U enable --now runner-vps"; echo $?)"
afirmar "o timer de validade foi habilitado" chamou_algo '^systemctl enable --now runner-vps-exemplo-validade.timer$'
afirmar "a validade fica gravada na configuração" grep -q '^VALIDADE=2026-12-31$' "$RAIZ/etc/runner-vps/exemplo.conf"
afirmar "o log do instalador diz a validade" grep -q '2026-12-31' "$TMP/out"
echo 2 > "$TMP/ocupado"
ciclo expirar; codigo=$?
afirmar "expirar: saída 0" test "$codigo" -eq 0
afirmar "expirar: espera o job, para e desabilita o runner" "$( bash -c 'grep -qxF "$2 stop runner-vps" "$1" && grep -qxF "$2 disable runner-vps" "$1" && [ "$(grep -c "^sleep 30\$" "$1")" -eq 2 ]' _ "$TMP/chamadas.log" "$U"; echo $?)"
afirmar "expirar: desabilita o timer de validade" chamou 'systemctl disable --now runner-vps-exemplo-validade.timer'
afirmar "expirar: deixa a marca com a data de hoje e a validade que venceu" \
  "$(grep -qxF "expirou_em=$HOJE" "$RAIZ/etc/runner-vps/exemplo.expirada" && grep -qxF 'validade=2026-12-31' "$RAIZ/etc/runner-vps/exemplo.expirada"; echo $?)"
rm -f "$TMP/ocupado"
ciclo ajustar
afirmar "depois de expirada, 'ajustar' não inicia nada" bash -c '! grep -qE "start runner-vps" "$1"' _ "$TMP/chamadas.log"
echo "validade: vencida durante a janela"
nova_vps
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00 VALIDADE=2026-11-20
CICLO_HOJE=2026-11-21 CICLO_AGORA=23:00 ciclo ajustar
afirmar "ajustar depois da data de validade expira em vez de iniciar" "$( bash -c 'grep -qxF "$2 disable runner-vps" "$1" && ! grep -qF "$2 start runner-vps" "$1"' _ "$TMP/chamadas.log" "$U"; echo $?)"
afirmar "ajustar vencido deixa a marca e desabilita os dois timers" "$(test -f "$RAIZ/etc/runner-vps/exemplo.expirada" && chamou 'systemctl disable --now runner-vps-exemplo-janela.timer' && chamou 'systemctl disable --now runner-vps-exemplo-validade.timer'; echo $?)"

echo "janela e validade: configuração inválida"
for ruim in 25:00-06:00 22:00-22:00 22:00 '22:00 - 06:00' 22:60-06:00 aa:bb-cc:dd '22:00-06:00;x'; do
  nova_vps; antes="$(snapshot "$RAIZ")"
  instalar JANELA="$ruim"; codigo=$?
  afirmar "JANELA '$ruim': saída 2 e nada criado" test "$codigo" -eq 2 -a "$antes" = "$(snapshot "$RAIZ")"
done
for ruim in 2026-13-01 2026-02-30 31/12/2026 amanha 2026-1-5; do
  nova_vps; antes="$(snapshot "$RAIZ")"
  instalar VALIDADE="$ruim"; codigo=$?
  afirmar "VALIDADE '$ruim': saída 2 e nada criado" test "$codigo" -eq 2 -a "$antes" = "$(snapshot "$RAIZ")"
done
nova_vps; antes="$(snapshot "$RAIZ")"
instalar VALIDADE=2020-01-01; codigo=$?
afirmar "VALIDADE no passado: saída 2, a mensagem diz que já passou e nada é criado" \
  test "$codigo" -eq 2 -a "$(grep -c 'já passou' "$TMP/err")" -eq 1 -a "$antes" = "$(snapshot "$RAIZ")"
instalar VALIDADE=2026-11-14; codigo=$?
afirmar "VALIDADE de hoje ainda vale (vence às 23:59)" test "$codigo" -eq 0
nova_vps
instalar JANELA_ESPERA_MIN=abc; codigo=$?
afirmar "JANELA_ESPERA_MIN inválido: saída 2" test "$codigo" -eq 2

echo "janela: sem registro ainda (sem token)"
nova_vps
env RUNNER_NOME=exemplo RUNNER_URL=$URL JANELA=22:00-06:00 CICLO_HOJE=$HOJE CICLO_AGORA=23:00 bash "$script" > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem registro: instala sem iniciar o runner (nada de start) e avisa" "$(test "$codigo" -eq 0 && bash -c '! grep -qF "$2 start runner-vps" "$1"' _ "$TMP/chamadas.log" "$U" && grep -q 'ainda não está registrado' "$TMP/err"; echo $?)"

echo "janela e validade: idempotência e reaplicação"
nova_vps
CICLO_AGORA=23:00 instalar JANELA=22:00-06:00 VALIDADE=2026-12-31
antes="$(snapshot "$RAIZ")"; : > "$TMP/chamadas.log"
CICLO_AGORA=23:00 reaplicar
afirmar "segunda execução igual: nada muda em disco e não há daemon-reload" \
  test "$antes" = "$(snapshot "$RAIZ")" -a "$(grep -c 'daemon-reload' "$TMP/chamadas.log")" -eq 0
afirmar "a configuração persistida vale sem repetir as variáveis (o timer continua lá)" \
  test -e "$RAIZ/$UNID/runner-vps-exemplo-janela.timer" -a -e "$RAIZ/$UNID/runner-vps-exemplo-validade.timer"
CICLO_AGORA=23:00 reaplicar JANELA=20:00-04:00
afirmar "mudar a janela reescreve o timer e faz daemon-reload" "$(grep -qxF 'OnCalendar=*-*-* 20:00:00' "$RAIZ/$UNID/runner-vps-exemplo-janela.timer" && chamou 'systemctl daemon-reload'; echo $?)"
afirmar "mudar a janela atualiza o script" grep -q '20:00' "$RAIZ/$CIC"
echo "janela e validade: remover as duas configurações"
CICLO_AGORA=23:00 reaplicar JANELA= VALIDADE=
afirmar "sem JANELA nem VALIDADE: unidades, script e marca somem" \
  test -z "$(ls "$RAIZ/$UNID" | grep 'runner-vps-exemplo')" -a ! -e "$RAIZ/$CIC" -a ! -e "$RAIZ/etc/runner-vps/exemplo.expirada"
afirmar "os timers foram desabilitados" "$(chamou 'systemctl disable --now runner-vps-exemplo-janela.timer' && chamou 'systemctl disable --now runner-vps-exemplo-validade.timer'; echo $?)"
afirmar "o serviço do runner volta a ser habilitado e iniciado" chamou "$U enable --now runner-vps"
afirmar "a configuração gravada fica sem janela nem validade" "$(grep -qE "^JANELA=(''|)\$" "$RAIZ/etc/runner-vps/exemplo.conf" && grep -qE "^VALIDADE=(''|)\$" "$RAIZ/etc/runner-vps/exemplo.conf"; echo $?)"

echo "validade: reativar uma instância expirada"
nova_vps
instalar VALIDADE=2026-11-20
CICLO_HOJE=2026-11-21 ciclo expirar
afirmar "expirada: marca presente" test -f "$RAIZ/etc/runner-vps/exemplo.expirada"
reaplicar; codigo=$?
afirmar "reaplicar sem mudar a VALIDADE vencida: saída 2, explica e não reabilita" \
  "$([ "$codigo" -eq 2 ] && grep -q 'expirou em 2026-11-21' "$TMP/err" && test -f "$RAIZ/etc/runner-vps/exemplo.expirada"; echo $?)"
instalar VALIDADE=2026-12-31
afirmar "reaplicar com nova validade apaga a marca e reabilita o runner" "$(test ! -e "$RAIZ/etc/runner-vps/exemplo.expirada" && chamou "$U enable --now runner-vps"; echo $?)"

echo "janela e validade: status e config"
nova_vps
instalar JANELA=22:00-06:00 VALIDADE=2026-12-31
RUNNER_NOME=exemplo bash "$script" --status > "$TMP/out" 2> "$TMP/err"
afirmar "status mostra a janela e a validade" "$(grep -q 'janela: 22:00-06:00' "$TMP/out" && grep -q 'validade: 2026-12-31' "$TMP/out"; echo $?)"
CICLO_HOJE=2026-12-31 ciclo expirar
RUNNER_NOME=exemplo bash "$script" --status > "$TMP/out" 2> "$TMP/err"
afirmar "status de instância expirada diz isso" grep -q 'expirada em 2026-12-31' "$TMP/out"
RUNNER_NOME=exemplo bash "$script" --config > "$TMP/out" 2> "$TMP/err"
afirmar "--config traz JANELA, VALIDADE e JANELA_ESPERA_MIN" "$(grep -q '^JANELA=22:00-06:00$' "$TMP/out" && grep -q '^VALIDADE=2026-12-31$' "$TMP/out" && grep -q '^JANELA_ESPERA_MIN=120$' "$TMP/out"; echo $?)"
nova_vps
instalar
RUNNER_NOME=exemplo bash "$script" --status > "$TMP/out" 2> "$TMP/err"
afirmar "sem nada configurado, o status diz 'sempre ligado' e 'sem validade'" "$(grep -q 'janela: sempre ligado' "$TMP/out" && grep -q 'validade: sem validade' "$TMP/out"; echo $?)"

echo "janela e validade: remover a instância limpa tudo"
nova_vps
instalar JANELA=22:00-06:00 VALIDADE=2026-12-31
env RUNNER_NOME=exemplo RUNNER_TOKEN="$TOKEN_FALSO" bash "$script" --remover > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "remover: saída 0" test "$codigo" -eq 0
afirmar "remover: nenhuma unidade, script nem marca de ciclo sobra" \
  test -z "$(ls "$RAIZ/$UNID" | grep 'runner-vps-exemplo')" -a ! -e "$RAIZ/$CIC"
afirmar "remover: desabilita os timers antes de apagar" "$(chamou 'systemctl disable --now runner-vps-exemplo-janela.timer' && chamou 'systemctl disable --now runner-vps-exemplo-validade.timer'; echo $?)"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"

echo "janela e validade: duas instâncias não se misturam"
MEM_LIVRE_MB=16384 nova_vps
instalar JANELA=22:00-06:00
env RUNNER_NOME=outra RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" CICLO_HOJE=$HOJE CICLO_AGORA=23:00 JANELA=01:00-02:00 MEMORY_MAX_MB=2048 bash "$script" > "$TMP/out" 2> "$TMP/err"
afirmar "cada instância tem os seus timers e o seu script" "$(grep -qxF 'OnCalendar=*-*-* 22:00:00' "$RAIZ/$UNID/runner-vps-exemplo-janela.timer" && grep -qxF 'OnCalendar=*-*-* 01:00:00' "$RAIZ/$UNID/runner-vps-outra-janela.timer" && test -x "$RAIZ/etc/runner-vps/ciclo-outra.sh"; echo $?)"

relatorio "janela e validade"
