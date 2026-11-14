#!/usr/bin/env bash
# Testes do painel de decisão do instalar.sh (--so-checar): somente leitura, com seções, estado das instâncias,
# avisos e veredito (Task 9 do plano). VPS falsa, sem rede, sem root.
set -uo pipefail
aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
URL=https://github.com/dono/repo
OUTRA_URL=https://github.com/dono/outro
export RUNNER_NOME=exemplo   # a instância padrão dos cenários

# rodar [args…]: roda o instalar.sh; stdout em $TMP/out, stderr em $TMP/err.
rodar() { bash "$script" "$@" > "$TMP/out" 2> "$TMP/err"; }
# painel: o --so-checar de uma instância; devolve o código.
painel() { rodar --so-checar; }
saida_tem() { grep -qF -- "$1" "$TMP/out"; }
linha() { grep -nF -- "$1" "$TMP/out" | head -n 1 | cut -d: -f1; }
ultima_linha() { grep -v '^[[:space:]]*$' "$TMP/out" | tail -n 1; }
instalar_instancia() { # <nome> <url> [VAR=valor…]
  local n="$1" u="$2"; shift 2
  env RUNNER_NOME="$n" RUNNER_URL="$u" RUNNER_TOKEN="$TOKEN_FALSO" MEMORY_MAX_MB=2048 CPU_QUOTA=200 "$@" bash "$script" > "$TMP/out" 2> "$TMP/err"
}
so_systemctl_is_active() { ! grep -v '^systemctl .* is-active ' "$TMP/chamadas.log" | grep -q .; }

echo "painel: VPS nova"
SWAP_MB=2048 nova_vps
printf 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\nVERSION_CODENAME=bookworm\n' > "$RAIZ/etc/os-release"
antes="$(snapshot "$TMP/raiz")"
RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" painel; codigo=$?
afirmar "VPS nova cabe: saída 0" test "$codigo" -eq 0
for secao in '== Sistema ==' '== Docker rootless ==' '== Instâncias nesta VPS ==' '== Esta instância (exemplo) ==' '== Avisos ==' '== Recursos e veredito =='; do
  afirmar "seção presente: $secao" saida_tem "$secao"
done
afirmar "as seções vêm na ordem do design" test \
  "$(linha '== Sistema ==')" -lt "$(linha '== Docker rootless ==')" -a \
  "$(linha '== Docker rootless ==')" -lt "$(linha '== Instâncias nesta VPS ==')" -a \
  "$(linha '== Instâncias nesta VPS ==')" -lt "$(linha '== Esta instância (exemplo) ==')" -a \
  "$(linha '== Esta instância (exemplo) ==')" -lt "$(linha '== Avisos ==')" -a \
  "$(linha '== Avisos ==')" -lt "$(linha '== Recursos e veredito ==')"
afirmar "distribuição" saida_tem 'sistema: Debian GNU/Linux 12 (bookworm)'
afirmar "arquitetura" saida_tem 'arquitetura: x86_64'
afirmar "kernel" saida_tem 'kernel: 6.1.0-falso'
afirmar "systemd presente" saida_tem 'systemd: sim'
afirmar "apt-get presente" saida_tem 'apt-get: sim'
afirmar "carga" saida_tem 'carga (1, 5, 15 min): 0.10 0.20 0.30'
afirmar "swap" saida_tem 'swap: 2048 MB'
afirmar "memória, CPUs e disco do diagnóstico" test "$(grep -c -E 'memória: 8192 MB no total|CPUs: 4; disco livre' "$TMP/out")" -eq 2
afirmar "instância nova" saida_tem 'situação: instalação nova'
afirmar "nenhuma instância ainda" saida_tem 'nenhuma instância instalada ainda'
afirmar "sem avisos" saida_tem 'nenhum aviso'
afirmar "o veredito é a última linha" test "$(ultima_linha | cut -c1-16)" = 'VEREDITO: cabe ('

echo "painel: somente leitura e sem vazar o token"
afirmar "RAIZ intacta (conteúdo e mtime)" test "$antes" = "$(snapshot "$TMP/raiz")"
afirmar "nenhum comando com efeito (só systemctl is-active)" so_systemctl_is_active
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"

echo "painel: instâncias e estado desta instância"
nova_vps
instalar_instancia exemplo "$URL"; c1=$?
instalar_instancia outra "$OUTRA_URL"; c2=$?
afirmar "duas instâncias instaladas para o cenário" test "$c1" -eq 0 -a "$c2" -eq 0
RUNNER_URL=$URL painel; codigo=$?
afirmar "instância existente: saída 0 (ainda cabe)" test "$codigo" -eq 0
afirmar "situação: já instalada" saida_tem 'situação: já instalada'
afirmar "usuário com uid" grep -qE 'usuário: runner-exemplo \(uid [0-9]+\)' "$TMP/out"
afirmar "serviço da instância" saida_tem 'serviço runner-vps: active'
afirmar "registro presente" saida_tem 'registro no GitHub: .runner presente'
afirmar "URL configurada" saida_tem "URL configurada: $URL"
afirmar "lista esta instância, marcada" saida_tem "exemplo (esta): $URL; MemoryMax=2048M; CPUQuota=200%; serviço: active"
afirmar "lista a outra instância" saida_tem "outra: $OUTRA_URL; MemoryMax=2048M; CPUQuota=200%; serviço: active"
afirmar "total de memória reservada" saida_tem 'memória reservada pelas instâncias: 4096 MB'
afirmar "sem avisos quando a URL confere" saida_tem 'nenhum aviso'

echo "painel: Docker rootless"
nova_vps
painel_com() { env "$@" bash "$script" --so-checar > "$TMP/out" 2> "$TMP/err"; }
painel; codigo=$?
afirmar "rootless ligado" saida_tem 'Docker rootless: ligado (DOCKER_ROOTLESS=1)'
afirmar "docker instalado" saida_tem 'docker: instalado'
afirmar "repositório apt do Docker ausente" saida_tem 'repositório apt do Docker: não configurado'
afirmar "user namespaces ok" saida_tem 'user namespaces: ok (max_user_namespaces=15000)'
afirmar "uidmap presente" saida_tem 'uidmap (newuidmap): presente'
mkdir -p "$RAIZ/etc/apt/sources.list.d"; printf 'URIs: https://download.docker.com/linux/debian\n' > "$RAIZ/etc/apt/sources.list.d/docker.sources"
painel
afirmar "repositório apt do Docker configurado" saida_tem 'repositório apt do Docker: configurado'
painel_com DOCKER_CMD=/nao/existe NEWUIDMAP_CMD=/nao/existe
afirmar "docker não instalado" saida_tem 'docker: não instalado'
afirmar "uidmap ausente" saida_tem 'uidmap (newuidmap): ausente'
rm -f "$USERNS_FILE"; painel; codigo=$?
afirmar "user namespaces desconhecido não bloqueia" test "$codigo" -eq 0
afirmar "user namespaces desconhecido aparece no painel" saida_tem 'user namespaces: desconhecido'
painel_com DOCKER_ROOTLESS=0
afirmar "rootless desligado" saida_tem 'Docker rootless: desligado (DOCKER_ROOTLESS=0)'
afirmar "rootless desligado não consulta user namespaces" test "$(grep -c 'user namespaces:' "$TMP/out")" -eq 0

echo "painel: motivos de 'não cabe'"
motivo() { # <descrição> <fragmento esperado no veredito> <código esperado>
  afirmar "$1: saída $3" test "$codigo" -eq "$3"
  afirmar "$1: veredito cita $2" grep -q "^VEREDITO: .*$2" "$TMP/out"
  afirmar "$1: o painel vem inteiro mesmo assim" test "$(grep -c -E '^== (Sistema|Docker rootless|Instâncias nesta VPS|Esta instância|Avisos|Recursos e veredito)' "$TMP/out")" -eq 6
}
MEM_LIVRE_MB=1500 nova_vps; painel; codigo=$?
motivo "memória baixa" 'memória' 1
nova_vps; rm -rf "$RAIZ/run/systemd"; painel; codigo=$?
motivo "sem systemd" 'systemd' 1
afirmar "sem systemd aparece como NÃO no painel" saida_tem 'systemd: NÃO'
nova_vps; APT_CMD=/nao/existe painel; codigo=$?
motivo "sem apt-get" 'apt-get' 1
afirmar "sem apt-get aparece como NÃO no painel" saida_tem 'apt-get: NÃO'
nova_vps; printf '0\n' > "$USERNS_FILE"; painel; codigo=$?
motivo "user namespaces desligados com rootless" 'user namespaces' 1
afirmar "user namespaces DESLIGADOS no painel" saida_tem 'user namespaces: DESLIGADOS (max_user_namespaces=0)'
nova_vps; printf '0\n' > "$USERNS_FILE"; DOCKER_ROOTLESS=0 painel; codigo=$?
afirmar "user namespaces desligados sem rootless: cabe" test "$codigo" -eq 0
nova_vps; rm -f "$USERNS_FILE"; painel; codigo=$?
afirmar "max_user_namespaces ausente: cabe" test "$codigo" -eq 0

echo "painel: avisos"
nova_vps
instalar_instancia exemplo "$URL"
RUNNER_URL="$OUTRA_URL" painel
afirmar "URL configurada diferente da informada" saida_tem "- a instância já está configurada para $URL, mas a URL informada é $OUTRA_URL"
nova_vps; printf '1\n' > "$APPARMOR_USERNS_FILE"; painel
afirmar "AppArmor restringindo user namespaces com rootless" saida_tem '- o AppArmor restringe user namespaces (apparmor_restrict_unprivileged_userns=1)'
nova_vps; printf '1\n' > "$APPARMOR_USERNS_FILE"; DOCKER_ROOTLESS=0 painel
afirmar "AppArmor sem rootless: sem aviso" saida_tem 'nenhum aviso'
nova_vps; printf '0\n' > "$APPARMOR_USERNS_FILE"; painel
afirmar "AppArmor liberado: sem aviso" saida_tem 'nenhum aviso'

echo "painel: a instalação também recusa"
nova_vps; printf '0\n' > "$USERNS_FILE"
antes="$(snapshot "$TMP/raiz")"
RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" rodar; codigo=$?
afirmar "user namespaces desligados: instalar sai com 1" test "$codigo" -eq 1
afirmar "user namespaces desligados: veredito não cabe" saida_tem 'VEREDITO: não cabe'
afirmar "user namespaces desligados: nada criado e nenhum usuário" test "$antes" = "$(snapshot "$TMP/raiz")" -a ! -s "$TMP/chamadas.log"
nova_vps; rm -rf "$RAIZ/run/systemd"
RUNNER_URL=$URL RUNNER_TOKEN="$TOKEN_FALSO" rodar; codigo=$?
afirmar "sem systemd: instalar sai com 1" test "$codigo" -eq 1
afirmar "sem systemd: nenhum useradd" test "$(grep -c '^useradd' "$TMP/chamadas.log")" -eq 0
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"

echo "painel: quanto falta de memória"
MEM_TOTAL_MB=3915 MEM_LIVRE_MB=1839 CPUS=2 nova_vps; painel; codigo=$?
afirmar "memória insuficiente: saída 1" test "$codigo" -eq 1
afirmar "mostra quanto sobraria e o mínimo" saida_tem 'memória insuficiente: sobrariam 768 MB para o runner (mínimo 2048 MB)'
afirmar "mostra quanto seria necessário e quanto falta" saida_tem 'seriam necessários 3072 MB disponíveis (faltam 1233 MB)'
afirmar "cita a reserva e as outras instâncias usadas na conta" saida_tem 'Com a reserva de 1024 MB e 0 MB de outras instâncias'
afirmar "a linha de números vem antes do veredito" test "$(linha 'memória insuficiente')" -lt "$(linha 'VEREDITO:')"
afirmar "o veredito continua sendo a última linha" grep -q '^VEREDITO: não cabe: memória' <<< "$(ultima_linha)"
RESERVA_MB=256 MEM_MIN_MB=1536 painel; codigo=$?
afirmar "com reserva e mínimo menores, cabe (saída 0)" test "$codigo" -eq 0
afirmar "e a linha de números não aparece" test "$(grep -c 'memória insuficiente' "$TMP/out")" -eq 0
nova_vps; painel
afirmar "VPS com folga: sem linha de memória insuficiente" test "$(grep -c 'memória insuficiente' "$TMP/out")" -eq 0
DISCO_LIVRE_GB=3 nova_vps; painel; codigo=$?
afirmar "não cabe só por disco: sem linha de memória insuficiente" test "$codigo" -eq 1 -a "$(grep -c 'memória insuficiente' "$TMP/out")" -eq 0

MEM_LIVRE_MB=4096 nova_vps
instalar_instancia outra "$OUTRA_URL"; c=$?
painel; codigo=$?
afirmar "com outra instância (2048 MB) já instalada: a conta a inclui" test "$c" -eq 0 -a "$codigo" -eq 1
afirmar "a conta soma mínimo, reserva e as outras instâncias" saida_tem 'Com a reserva de 1024 MB e 2048 MB de outras instâncias, seriam necessários 5120 MB disponíveis (faltam 1024 MB)'

relatorio "painel de decisão"
