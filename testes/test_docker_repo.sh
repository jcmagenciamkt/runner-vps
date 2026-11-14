#!/usr/bin/env bash
# Testes da configuração do repositório apt do Docker pelo instalar.sh: chave fixada pelo fingerprint.
set -uo pipefail
aqui="$(cd "$(dirname "$0")" && pwd)"
script="$aqui/../instalar.sh"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
# shellcheck source=testes/vps-falsa.sh
source "$aqui/vps-falsa.sh"

if ! command -v gpg > /dev/null 2>&1; then echo "  FALHA gpg não está instalado (os testes do repositório do Docker precisam dele)"; exit 1; fi

rodar() { bash "$script" > "$TMP/out" 2> "$TMP/err"; }
chamou() { grep -qF -- "$1" "$TMP/chamadas.log"; }
linha_de() { grep -nF -- "$1" "$TMP/chamadas.log" | head -n 1 | cut -d: -f1; }
tudo() { cat "$TMP/out" "$TMP/err"; }
apt_ruim="$TMP/bin/rootless-tardio"
# vps_sem_docker: VPS falsa em que o setuptool só aparece depois que o apt "instala" docker-ce-rootless-extras.
vps_sem_docker() {
  nova_vps
  rm -f "$apt_ruim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "rootless $*" >> "$TMP/chamadas.log"\n' > "$TMP/bin/rootless-do-pacote"
  cat > "$TMP/bin/apt" <<FALSO
#!/usr/bin/env bash
printf '%s\n' "apt \$*" >> "\$TMP/chamadas.log"
case " \$* " in *" docker-ce-rootless-extras "*) cp "$TMP/bin/rootless-do-pacote" "$apt_ruim" ;; esac
FALSO
  chmod +x "$TMP/bin/apt" "$TMP/bin/rootless-do-pacote"
  export ROOTLESS_CMD="$apt_ruim"
}
instalar() { RUNNER_NOME=exemplo RUNNER_URL=https://github.com/dono/repo rodar; }
fonte="$TMP/raiz/etc/apt/sources.list.d/docker.sources"
chave="$TMP/raiz/etc/apt/keyrings/docker.gpg"

gerar_chave_falsa "$TMP/chave-boa.asc"; fpr_bom="$CHAVE_FPR"
gerar_chave_falsa "$TMP/chave-outra.asc"; fpr_outro="$CHAVE_FPR"
cat "$TMP/chave-boa.asc" "$TMP/chave-outra.asc" > "$TMP/chave-dupla.asc"
afirmar "as chaves de teste foram geradas (fingerprints distintos)" test -n "$fpr_bom" -a -n "$fpr_outro" -a "$fpr_bom" != "$fpr_outro"

echo "repositório do Docker: instalação num Debian sem Docker"
vps_sem_docker
BAIXAR_CHAVE="$TMP/chave-boa.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "instala com saída 0" test "$codigo" -eq 0
afirmar "baixa a chave do download.docker.com/linux/debian" chamou "baixar https://download.docker.com/linux/debian/gpg"
afirmar "instala ca-certificates, curl e gnupg antes" bash -c 'grep -E "^apt " "$1" | grep -q "ca-certificates curl gnupg"' _ "$TMP/chamadas.log"
afirmar "o chaveiro tem só a chave fixada" \
  test "$(gpg --show-keys --with-colons "$chave" 2> /dev/null | awk -F: '$1=="fpr"{print $10; exit}')" = "$fpr_bom"
afirmar "o chaveiro tem exatamente uma chave primária" test "$(gpg --show-keys --with-colons "$chave" 2> /dev/null | grep -c '^pub:')" -eq 1
afirmar "fonte deb822 com URIs, Suites, Components e Signed-By" \
  bash -c 'grep -qx "Types: deb" "$1" && grep -qx "URIs: https://download.docker.com/linux/debian" "$1" && grep -qx "Suites: bookworm" "$1" && grep -qx "Components: stable" "$1" && grep -qx "Signed-By: /etc/apt/keyrings/docker.gpg" "$1"' _ "$fonte"
afirmar "apt update depois de gravar a fonte e antes de instalar o docker-ce" \
  test "$(linha_de 'apt update')" -lt "$(linha_de 'docker-ce-rootless-extras')"
afirmar "instala docker-ce, docker-ce-rootless-extras e docker-compose-plugin" \
  bash -c 'grep -E "^apt install" "$1" | grep -q "docker-ce docker-ce-rootless-extras docker-compose-plugin"' _ "$TMP/chamadas.log"
afirmar "a instalação segue até o Docker rootless (check e install)" bash -c 'grep -q "^rootless check" "$1" && grep -q "^rootless install" "$1"' _ "$TMP/chamadas.log"

echo "repositório do Docker: segunda execução"
antes="$(snapshot "$TMP/raiz")"; : > "$TMP/chamadas.log"
RUNNER_NOME=exemplo rodar; codigo=$?
afirmar "segunda execução: saída 0" test "$codigo" -eq 0
afirmar "segunda execução: não baixa a chave de novo" bash -c '! grep -q "download.docker.com" "$1"' _ "$TMP/chamadas.log"
afirmar "segunda execução: nada alterado" test "$antes" = "$(snapshot "$TMP/raiz")"

echo "repositório do Docker: Ubuntu"
vps_sem_docker
printf 'ID=ubuntu\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\nID_LIKE=debian\n' > "$TMP/raiz/etc/os-release"
BAIXAR_CHAVE="$TMP/chave-boa.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "ubuntu: saída 0" test "$codigo" -eq 0
afirmar "ubuntu: baixa a chave de linux/ubuntu" chamou "baixar https://download.docker.com/linux/ubuntu/gpg"
afirmar "ubuntu: fonte com URIs ubuntu e Suites jammy" \
  bash -c 'grep -qx "URIs: https://download.docker.com/linux/ubuntu" "$1" && grep -qx "Suites: jammy" "$1"' _ "$fonte"

echo "repositório do Docker: recusas"
# fingerprint diferente do fixado
vps_sem_docker; antes="$(snapshot "$TMP/raiz")"
BAIXAR_CHAVE="$TMP/chave-outra.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "fingerprint diferente: saída 1" test "$codigo" -eq 1
afirmar "fingerprint diferente: a mensagem fala do fingerprint" bash -c 'tudo="$(cat "$1" "$2")"; case "$tudo" in *fingerprint*) exit 0;; *) exit 1;; esac' _ "$TMP/out" "$TMP/err"
afirmar "fingerprint diferente: nenhum chaveiro nem fonte do Docker" test ! -e "$chave" -a ! -e "$fonte"
afirmar "fingerprint diferente: não instala o docker-ce" bash -c '! grep -q "docker-ce" "$1"' _ "$TMP/chamadas.log"
# arquivo com a chave certa e mais uma: o apt confiaria nas duas
vps_sem_docker
BAIXAR_CHAVE="$TMP/chave-dupla.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "arquivo com chave extra: saída 1" test "$codigo" -eq 1
afirmar "arquivo com chave extra: nenhum chaveiro nem fonte" test ! -e "$chave" -a ! -e "$fonte"
# arquivo que não é chave
vps_sem_docker
printf 'isto não é uma chave\n' > "$TMP/lixo.asc"
BAIXAR_CHAVE="$TMP/lixo.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "arquivo que não é chave: saída 1" test "$codigo" -eq 1
afirmar "arquivo que não é chave: nenhum chaveiro nem fonte" test ! -e "$chave" -a ! -e "$fonte"
# download falhando
vps_sem_docker
instalar; codigo=$?
afirmar "download da chave falhando: saída 1" test "$codigo" -eq 1
afirmar "download da chave falhando: nenhum chaveiro nem fonte" test ! -e "$chave" -a ! -e "$fonte"
# distribuição sem suporte
vps_sem_docker
printf 'ID=alpine\nVERSION_CODENAME=\n' > "$TMP/raiz/etc/os-release"
BAIXAR_CHAVE="$TMP/chave-boa.asc" DOCKER_APT_FINGERPRINT="$fpr_bom" instalar; codigo=$?
afirmar "distribuição sem suporte: saída 1" test "$codigo" -eq 1
afirmar "distribuição sem suporte: a mensagem cita a distribuição" bash -c 'tudo="$(cat "$1" "$2")"; case "$tudo" in *distribuição*) exit 0;; *) exit 1;; esac' _ "$TMP/out" "$TMP/err"
afirmar "distribuição sem suporte: não baixa a chave" bash -c '! grep -q "download.docker.com" "$1"' _ "$TMP/chamadas.log"

echo "repositório do Docker: casos em que não mexe no apt"
# repositório do Docker já configurado pelo dono
vps_sem_docker
printf 'deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable\n' > "$TMP/raiz/etc/apt/sources.list.d/docker.list"
instalar; codigo=$?
afirmar "repositório já configurado: saída 0" test "$codigo" -eq 0
afirmar "repositório já configurado: não baixa a chave" bash -c '! grep -q "download.docker.com" "$1"' _ "$TMP/chamadas.log"
afirmar "repositório já configurado: não cria a fonte nem o chaveiro" test ! -e "$fonte" -a ! -e "$chave"
afirmar "repositório já configurado: instala os pacotes do Docker" bash -c 'grep -E "^apt install" "$1" | grep -q docker-ce-rootless-extras' _ "$TMP/chamadas.log"
# setuptool já presente (Docker já instalado): não toca no repositório
nova_vps
instalar; codigo=$?
afirmar "docker já instalado: saída 0" test "$codigo" -eq 0
afirmar "docker já instalado: nenhum repositório configurado" test ! -e "$fonte" -a ! -e "$chave"
afirmar "docker já instalado: apt não pede docker-ce" bash -c '! grep -E "^apt " "$1" | grep -q docker-ce' _ "$TMP/chamadas.log"
# DOCKER_ROOTLESS=0: nunca configura o repositório, mesmo sem o setuptool
vps_sem_docker
DOCKER_ROOTLESS=0 instalar; codigo=$?
afirmar "DOCKER_ROOTLESS=0: saída 0" test "$codigo" -eq 0
afirmar "DOCKER_ROOTLESS=0: nunca configura o repositório" test ! -e "$fonte" -a ! -e "$chave"
afirmar "DOCKER_ROOTLESS=0: não baixa a chave" bash -c '! grep -q "download.docker.com" "$1"' _ "$TMP/chamadas.log"

relatorio "repositório do Docker"
