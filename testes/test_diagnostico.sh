#!/usr/bin/env bash
# Testes do instalar.sh: argumentos, configuração persistida, diagnóstico e veredito (Task 2 do plano).
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"

# nova_vps: recomeça do zero (RAIZ, comandos falsos, registro de chamadas), com os parâmetros do ambiente.
nova_vps() {
  rm -rf "$TMP/raiz" "$TMP/runner-fonte"
  : > "$TMP/chamadas.log"
  montar_vps_falsa
}
# rodar [args…]: roda o instalar.sh com stdout em $TMP/out e stderr em $TMP/err; devolve o código.
rodar() { bash "$script" "$@" > "$TMP/out" 2> "$TMP/err"; }
saida_tem() { grep -qF -- "$1" "$TMP/out"; }
conf="$TMP/raiz/etc/runner-vps/exemplo.conf"

echo "instalar.sh: argumentos"

nova_vps
for sub in --status --remover ''; do
  RUNNER_NOME='' rodar $sub; codigo=$?
  afirmar "sem RUNNER_NOME (${sub:-instalar}): saída 2" test "$codigo" -eq 2
  afirmar "sem RUNNER_NOME (${sub:-instalar}): a mensagem cita RUNNER_NOME" grep -q RUNNER_NOME "$TMP/err"
done
# (o painel do servidor, --so-checar, é a exceção: ver test_painel.sh)
for ruim in Foo 'a b' 'a_b' '-'; do
  [ "$ruim" = '-' ] && ruim='A'
  RUNNER_NOME="$ruim" rodar --so-checar; codigo=$?
  afirmar "nome inválido '$ruim': saída 2" test "$codigo" -eq 2
done
RUNNER_NOME=exemplo rodar --nao-existe; codigo=$?
afirmar "argumento desconhecido: saída 2" test "$codigo" -eq 2

# Sem ser root: um `id` falso devolve 1000 e SOU_ROOT não está ligado.
mkdir -p "$TMP/idbin"; printf '#!/usr/bin/env bash\necho 1000\n' > "$TMP/idbin/id"; chmod +x "$TMP/idbin/id"
antes="$(snapshot "$TMP/raiz")"
PATH="$TMP/idbin:$PATH" SOU_ROOT='' RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo rodar; codigo=$?
afirmar "sem ser root: saída 1" test "$codigo" -eq 1
afirmar "sem ser root: nenhum arquivo criado ou alterado" test "$antes" = "$(snapshot "$TMP/raiz")"

echo "instalar.sh: diagnóstico e veredito"

# 2. VPS folgada
nova_vps
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "folgada: --so-checar sai com 0" test "$codigo" -eq 0
afirmar "folgada: VEREDITO cabe (5120M, 300%)" saida_tem "VEREDITO: cabe (MemoryMax=5120M CPUQuota=300%)"
afirmar "--so-checar não chama comando com efeito" test ! -s "$TMP/chamadas.log"
afirmar "--so-checar não cria nada em RAIZ" test ! -e "$TMP/raiz/etc/runner-vps"
RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo rodar; codigo=$?
afirmar "folgada: instalar também dá o veredito e sai com 0" test "$codigo" -eq 0
afirmar "folgada: instalar mostra VEREDITO cabe" saida_tem "VEREDITO: cabe (MemoryMax=5120M CPUQuota=300%)"

# 3. memória, CPU e disco
MEM_LIVRE_MB=2560 nova_vps
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "2560 MB livres: saída 1" test "$codigo" -eq 1
afirmar "2560 MB livres: VEREDITO não cabe: memória" saida_tem "VEREDITO: não cabe: memória"
CPUS=1 nova_vps
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "1 CPU: cabe com CPUQuota=100%" saida_tem "CPUQuota=100%"
afirmar "1 CPU: saída 0" test "$codigo" -eq 0
DISCO_LIVRE_GB=6 nova_vps
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "6 GB de disco: saída 1" test "$codigo" -eq 1
afirmar "6 GB de disco: VEREDITO não cabe: disco" saida_tem "VEREDITO: não cabe: disco"

# 4. outra instância já instalada
outra_instancia() { # <MEMORY_MAX_MB>
  mkdir -p "$TMP/raiz/etc/runner-vps"
  printf 'RUNNER_URL=https://github.com/dono/outro\nMEMORY_MAX_MB=%s\n' "$1" > "$TMP/raiz/etc/runner-vps/outra.conf"
}
nova_vps; outra_instancia 3072
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "outra instância de 3072 MB, 6144 livres: sobra 2048 e cabe" saida_tem "VEREDITO: cabe (MemoryMax=2048M CPUQuota=300%)"
afirmar "outra instância: saída 0" test "$codigo" -eq 0
MEM_LIVRE_MB=5120 nova_vps; outra_instancia 3072
RUNNER_NOME=exemplo rodar --so-checar; codigo=$?
afirmar "outra instância de 3072 MB, 5120 livres: não cabe" saida_tem "VEREDITO: não cabe: memória"
afirmar "outra instância, 5120 livres: saída 1" test "$codigo" -eq 1

# 5. limites fixados à mão
nova_vps
RUNNER_NOME=exemplo MEMORY_MAX_MB=1024 rodar --so-checar; codigo=$?
afirmar "MEMORY_MAX_MB=1024 fixado: não cabe, mínimo 2048" saida_tem "VEREDITO: não cabe: memória (mínimo 2048)"
afirmar "MEMORY_MAX_MB=1024 fixado: saída 1" test "$codigo" -eq 1
RUNNER_NOME=exemplo MEMORY_MAX_MB=4096 CPU_QUOTA=200 rodar --so-checar; codigo=$?
afirmar "limites fixados acima do mínimo valem" saida_tem "VEREDITO: cabe (MemoryMax=4096M CPUQuota=200%)"
RUNNER_NOME=exemplo CPU_QUOTA=50% rodar --so-checar; codigo=$?
afirmar "CPU_QUOTA=50% fixado: não cabe: cpu" saida_tem "VEREDITO: não cabe: cpu"
RUNNER_NOME=exemplo MEM_MIN_MB=abc rodar --so-checar; codigo=$?
afirmar "valor numérico inválido: saída 2" test "$codigo" -eq 2

# "Não cabe" não cria nada, mesmo com token e URL
MEM_LIVRE_MB=2560 nova_vps
antes="$(snapshot "$TMP/raiz")"
RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo RUNNER_TOKEN="$TOKEN_FALSO" rodar; codigo=$?
afirmar "não cabe com token: saída 1" test "$codigo" -eq 1
afirmar "não cabe com token: nenhum arquivo criado" test "$antes" = "$(snapshot "$TMP/raiz")"
afirmar "não cabe com token: nenhum comando com efeito" test ! -s "$TMP/chamadas.log"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"

echo "instalar.sh: configuração persistida"

nova_vps
RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "primeiro instalar sem RUNNER_URL: saída 2" test "$codigo" -eq 2
afirmar "primeiro instalar sem RUNNER_URL: nada gravado" test ! -e "$conf"

RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo RUNNER_ROTULOS=a,b RUNNER_TOKEN="$TOKEN_FALSO" rodar; codigo=$?
afirmar "com RUNNER_URL: saída 0" test "$codigo" -eq 0
afirmar ".conf criado" test -f "$conf"
afirmar ".conf com chmod 600" test "$(stat -c %a "$conf")" = 600
afirmar ".conf guarda a URL, os rótulos e os limites calculados (relidos com source)" \
  bash -c '. "$1"; [ "$RUNNER_URL" = https://github.com/dono/repo ] && [ "$RUNNER_ROTULOS" = a,b ] && [ "$MEMORY_MAX_MB" = 5120 ] && [ "$CPU_QUOTA" = 300 ]' _ "$conf"
afirmar ".conf sem a palavra token" bash -c '! grep -qi token "$1"' _ "$conf"
afirmar_sem "$TMP/raiz" "$TOKEN_FALSO"
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"

# sem variáveis, o .conf é a fonte; segunda execução não altera nada (conteúdo e mtime)
antes="$(snapshot "$TMP/raiz")"
RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "só com RUNNER_NOME, usa o .conf: saída 0" test "$codigo" -eq 0
afirmar "usa a URL do .conf" saida_tem "https://github.com/dono/repo"
afirmar "segunda execução sem mudanças: nada alterado" test "$antes" = "$(snapshot "$TMP/raiz")"

# variável presente sobrescreve e o .conf é reescrito
sleep 0.01
RUNNER_NOME=exemplo RUNNER_ROTULOS=novo rodar; codigo=$?
afirmar "variável sobrescreve: saída 0" test "$codigo" -eq 0
afirmar "variável sobrescreve: .conf reescrito com o valor novo" \
  bash -c '. "$1"; [ "$RUNNER_ROTULOS" = novo ]' _ "$conf"
afirmar "variável sobrescreve: o resto do .conf fica" \
  bash -c '. "$1"; [ "$RUNNER_URL" = https://github.com/dono/repo ]' _ "$conf"
afirmar "variável sobrescreve: .conf segue com chmod 600" test "$(stat -c %a "$conf")" = 600

# valores com espaço e aspas voltam intactos
RUNNER_NOME=exemplo HOSTS_EXTRAS="127.0.0.1 app.exemplo.test" ENV_EXTRAS="A=1;B=dois três" rodar
RUNNER_NOME=exemplo rodar --so-checar
afirmar "valores com espaço persistem e são relidos" \
  bash -c '. "$1"; [ "$HOSTS_EXTRAS" = "127.0.0.1 app.exemplo.test" ] && [ "$ENV_EXTRAS" = "A=1;B=dois três" ]' _ "$conf"

relatorio "instalar.sh (diagnóstico)"
