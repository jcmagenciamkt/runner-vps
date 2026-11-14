#!/usr/bin/env bash
# Testes de instalar.sh --verificar (Task 17): checklist pós-instalação, somente leitura, contra a VPS falsa.
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
# todos <condição…>: cada argumento é um comando (avaliado com eval); ok só se todos saírem com 0.
todos() { local c; for c in "$@"; do eval "$c" || return 1; done; }
verificar() { RUNNER_NOME=exemplo bash "$script" --verificar > "$TMP/out" 2> "$TMP/err"; }
sem_mutacao() { ! mutou; }
mutou() { grep -qE 'systemctl .*(start|stop|restart|enable|disable|daemon-reload)|useradd|userdel|chown|loginctl' "$TMP/chamadas.log"; }
unidade="$TMP/raiz/opt/runner-vps/exemplo/.config/systemd/user/runner-vps.service"

# Comandos de leitura falsos (cada um tem a sua variável _CMD no instalar.sh).
cat > "$TMP/bin/dono-falso" <<'F'
#!/usr/bin/env bash
# DONO_CMD <caminho>: dono do arquivo; $TMP/dono-override tem linhas "sufixo dono"
while read -r suf dono; do case "$1" in *"$suf") echo "$dono"; exit 0 ;; esac; done < "$TMP/dono-override" 2> /dev/null
echo runner-exemplo
F
cat > "$TMP/bin/grupos-falso" <<'F'
#!/usr/bin/env bash
# GRUPOS_CMD <usuario>: grupos do usuário
cat "$TMP/grupos" 2> /dev/null || echo runner-exemplo
F
cat > "$TMP/bin/pgrep-falso" <<'F'
#!/usr/bin/env bash
# PGREP_CMD -u <usuario> -f <padrão>: $TMP/procs tem linhas "usuário padrão"
usuario=""; padrao=""
while [ "$#" -gt 0 ]; do case "$1" in -u) usuario="$2"; shift ;; -f) padrao="$2"; shift ;; esac; shift; done
grep -qxF "$usuario $padrao" "$TMP/procs" 2> /dev/null
F
cat > "$TMP/bin/journalctl-falso" <<'F'
#!/usr/bin/env bash
printf '%s\n' "journalctl $*" >> "$TMP/chamadas.log"
[ "${JOURNAL_SAIDA:-0}" = 0 ] || exit "$JOURNAL_SAIDA"
cat "$TMP/journal" 2> /dev/null
exit 0
F
cat > "$TMP/bin/systemctl-parado" <<'F'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >> "$TMP/chamadas.log"
case " $* " in *" is-active "*) echo "${ESTADO:-inactive}"; exit 3 ;; *" is-enabled "*) echo enabled ;; esac
exit 0
F
chmod +x "$TMP/bin/dono-falso" "$TMP/bin/grupos-falso" "$TMP/bin/pgrep-falso" "$TMP/bin/journalctl-falso" "$TMP/bin/systemctl-parado"

# cenario [VAR=valor…]: VPS nova com a instância "exemplo" instalada e tudo certo.
cenario() {
  MEM_LIVRE_MB=16384 nova_vps
  rm -f "$TMP/dono-override" "$TMP/grupos" "$TMP/journal"
  printf 'runner-exemplo Runner.Listener\n' > "$TMP/procs"
  env RUNNER_NOME=exemplo RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" MEMORY_MAX_MB=2048 "$@" bash "$script" > "$TMP/out" 2> "$TMP/err"
  : > "$TMP/chamadas.log"
  export DONO_CMD="$TMP/bin/dono-falso" GRUPOS_CMD="$TMP/bin/grupos-falso" PGREP_CMD="$TMP/bin/pgrep-falso" JOURNALCTL_CMD="$TMP/bin/journalctl-falso"
}

echo "instalar.sh --verificar: tudo certo"
cenario
antes="$(snapshot "$TMP/raiz")"
verificar; codigo=$?
afirmar "instância saudável: saída 0" test "$codigo" -eq 0
afirmar "cada checagem aparece como ok" test "$(grep -c '^ok: ' "$TMP/out")" -ge 9
afirmar "nenhuma FALHA" test "$(grep -c '^FALHA' "$TMP/out")" -eq 0
afirmar "resumo final: VERIFICAÇÃO: ok" saida_tem 'VERIFICAÇÃO: ok'
afirmar "diz o ExecStart conferido" saida_tem "ok: unidade: ExecStart=/opt/runner-vps/exemplo/runner/run.sh"
afirmar "diz que o Runner.Listener roda como o usuário da instância" saida_tem 'ok: processo: Runner.Listener roda como runner-exemplo'
afirmar "diz que não há sudo nem grupo docker" saida_tem 'ok: privilégios: sem sudo e sem o grupo docker'
afirmar "somente leitura: nenhum arquivo mudou" test "$antes" = "$(snapshot "$TMP/raiz")"
afirmar "somente leitura: nenhum comando com efeito" sem_mutacao
afirmar "sem token na saída" bash -c '! grep -q "$2" "$1" "$3"' _ "$TMP/out" "$TOKEN_FALSO" "$TMP/err"

echo "instalar.sh --verificar: o que dá errado"
checa_falha() { # <descrição> <texto esperado na saída>
  verificar; codigo=$?
  afirmar "$1: saída 1" test "$codigo" -eq 1
  afirmar "$1: FALHA com a mensagem certa" saida_tem "$2"
  afirmar "$1: resumo diz que falhou e lista o diagnóstico" test "$(grep -c -E 'VERIFICAÇÃO: falhou|journalctl _UID=|status runner-vps' "$TMP/out")" -ge 3
}
cenario; rm -rf "$TMP/raiz/opt/runner-vps/exemplo/runner/.runner"
checa_falha ".runner ausente" 'FALHA: registro: .runner ausente'
cenario; rm -f "$TMP/raiz/opt/runner-vps/exemplo/runner/run.sh"
checa_falha "run.sh ausente" 'FALHA: arquivos: run.sh ausente'
cenario; chmod -x "$TMP/raiz/opt/runner-vps/exemplo/runner/run.sh"
checa_falha "run.sh sem permissão de execução" 'FALHA: arquivos: run.sh sem permissão de execução'
cenario; printf '/runner/run.sh root\n' > "$TMP/dono-override"
checa_falha "run.sh de root" 'FALHA: dono: '
cenario; printf 'runner-exemplo sudo\n' > "$TMP/grupos"
checa_falha "usuário no grupo sudo" 'FALHA: privilégios: o usuário está no grupo sudo'
cenario; printf 'runner-exemplo wheel\n' > "$TMP/grupos"
checa_falha "usuário no grupo wheel" 'FALHA: privilégios: o usuário está no grupo wheel'
cenario; printf 'runner-exemplo admin\n' > "$TMP/grupos"
checa_falha "usuário no grupo admin" 'FALHA: privilégios: o usuário está no grupo admin'
cenario; sed -i 's|^WorkingDirectory=.*|WorkingDirectory=/home/outro|' "$unidade"
checa_falha "WorkingDirectory errado" 'FALHA: unidade: WorkingDirectory aponta para /home/outro'
cenario; printf '/exemplo/runner root\n' > "$TMP/dono-override"
checa_falha "diretório do runner de root" 'FALHA: dono: /opt/runner-vps/exemplo/runner é de root'
cenario; printf 'runner-exemplo docker\n' > "$TMP/grupos"
checa_falha "usuário no grupo docker" 'FALHA: privilégios: o usuário está no grupo docker'
cenario; mkdir -p "$TMP/raiz/etc/sudoers.d"; printf 'runner-exemplo ALL=(ALL) NOPASSWD:ALL\n' > "$TMP/raiz/etc/sudoers.d/runner"
checa_falha "sudoers concede sudo" 'FALHA: privilégios: o sudoers dá sudo'
cenario; sed -i 's|^ExecStart=.*|ExecStart=/home/outro/actions-runner/runsvc.sh|' "$unidade"
checa_falha "ExecStart errado" 'FALHA: unidade: ExecStart aponta para /home/outro/actions-runner/runsvc.sh'
cenario; rm -f "$unidade"
checa_falha "unidade ausente" 'FALHA: unidade: arquivo ausente'
cenario; : > "$TMP/procs"
checa_falha "Runner.Listener não roda" 'FALHA: processo: Runner.Listener não está rodando como runner-exemplo'
cenario; printf 'root Runner.Listener\n' > "$TMP/procs"
checa_falha "Runner.Listener rodando como root" 'FALHA: processo: Runner.Listener rodando como root'
cenario; rm -f "$TMP/raiz/var/lib/systemd/linger/runner-exemplo"
checa_falha "linger desligado" 'FALHA: linger: '
printf 'abr 01 systemd[1]: runner-vps.service: Failed at step CHDIR spawning run.sh: No such file or directory\n' > "$TMP/journal"
cenario; printf 'abr 01 systemd[1]: runner-vps.service: Failed at step CHDIR spawning run.sh: No such file or directory\n' > "$TMP/journal"
checa_falha "journal com erro de CHDIR" 'FALHA: journal: erro de diretório de trabalho'
cenario; printf 'runner-vps[1]: /opt/x/runner/externals/node24/bin/node: No such file or directory\n' > "$TMP/journal"
checa_falha "journal com erro de node" 'FALHA: journal: erro de diretório de trabalho'
cenario; printf 'abr 01 runner-vps[1]: Listening for Jobs\n' > "$TMP/journal"
verificar; codigo=$?
afirmar "journal normal não é erro" test "$codigo" -eq 0
cenario; JOURNAL_SAIDA=1 verificar; codigo=$?
afirmar "journal ilegível é só aviso (saída 0)" todos 'test "$codigo" -eq 0' "saida_tem 'aviso: journal: não consegui ler'"

cenario; SYSTEMCTL_CMD="$TMP/bin/systemctl-parado" verificar; codigo=$?
afirmar "serviço parado: saída 1 com o estado" todos 'test "$codigo" -eq 1' "saida_tem 'FALHA: serviço: runner-vps está inactive'"
cenario; ESTADO=failed SYSTEMCTL_CMD="$TMP/bin/systemctl-parado" verificar
afirmar "serviço failed aparece como failed" saida_tem 'FALHA: serviço: runner-vps está failed'

echo "instalar.sh --verificar: janela e validade não são falha"
cenario JANELA=22:00-06:00; SYSTEMCTL_CMD="$TMP/bin/systemctl-parado" verificar; codigo=$?
afirmar "com janela, serviço parado é só aviso (saída 0)" todos 'test "$codigo" -eq 0' "saida_tem 'aviso: serviço: runner-vps está inactive'" "! saida_tem 'FALHA'"
cenario JANELA=22:00-06:00; : > "$TMP/procs"; SYSTEMCTL_CMD="$TMP/bin/systemctl-parado" verificar; codigo=$?
afirmar "com janela, sem processo também é só aviso" todos 'test "$codigo" -eq 0' "saida_tem 'aviso: processo: Runner.Listener não está rodando'"
cenario VALIDADE=2999-12-31; mkdir -p "$TMP/raiz/etc/runner-vps"; printf 'expirou_em=2999-12-31\n' > "$TMP/raiz/etc/runner-vps/exemplo.expirada"; : > "$TMP/procs"; SYSTEMCTL_CMD="$TMP/bin/systemctl-parado" verificar; codigo=$?
afirmar "instância expirada parada: aviso, não falha" todos 'test "$codigo" -eq 0' "saida_tem 'aviso: serviço: instância expirada'"

echo "instalar.sh --verificar: usos inválidos"
MEM_LIVRE_MB=16384 nova_vps
RUNNER_NOME=inexistente bash "$script" --verificar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "instância inexistente: saída 1 com mensagem" todos 'test "$codigo" -eq 1' "grep -q 'não existe' \"$TMP/err\""
env -u RUNNER_NOME bash "$script" --verificar > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem RUNNER_NOME: saída 2" test "$codigo" -eq 2

relatorio "instalar.sh (verificar)"
