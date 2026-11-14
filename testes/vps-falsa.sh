#!/usr/bin/env bash
# VPS falsa para testar o instalar.sh. Uso: `source testes/harness.sh; source testes/vps-falsa.sh; montar_vps_falsa`.
# Parâmetros (ambiente, com padrão): MEM_TOTAL_MB=8192 MEM_LIVRE_MB=6144 CPUS=4 DISCO_LIVRE_GB=40.
# Exporta as variáveis de substituição da lista fechada do plano. O instalador real nunca é tocado.

montar_vps_falsa() {
  local total="${MEM_TOTAL_MB:-8192}" livre="${MEM_LIVRE_MB:-6144}" cpus="${CPUS:-4}" disco="${DISCO_LIVRE_GB:-40}"

  export RAIZ="$TMP/raiz"
  mkdir -p "$RAIZ/etc/systemd/system" "$RAIZ/opt" "$RAIZ/run" "$RAIZ/proc" "$RAIZ/var/tmp"
  : > "$RAIZ/etc/subuid"; : > "$RAIZ/etc/subgid"
  printf '127.0.0.1 localhost\n' > "$RAIZ/etc/hosts"

  # /proc/meminfo falso (em kB, como o real)
  export MEMINFO_FILE="$RAIZ/proc/meminfo"
  printf 'MemTotal:       %s kB\nMemFree:        %s kB\nMemAvailable:   %s kB\n' \
    "$((total * 1024))" "$((livre * 1024))" "$((livre * 1024))" > "$MEMINFO_FILE"

  # nproc e df falsos. DF_CMD imita `df -BG --output=avail <caminho>`: cabeçalho e "  40G".
  printf '#!/usr/bin/env bash\necho %s\n' "$cpus" > "$TMP/bin/nproc-falso"
  printf '#!/usr/bin/env bash\nprintf "Avail\\n %%sG\\n" %s\n' "$disco" > "$TMP/bin/df-falso"
  chmod +x "$TMP/bin/nproc-falso" "$TMP/bin/df-falso"
  export NPROC_CMD="$TMP/bin/nproc-falso" DF_CMD="$TMP/bin/df-falso"

  # Comandos com efeito: todos falsos, só registram a chamada em $TMP/chamadas.log.
  local c
  for c in useradd userdel loginctl systemctl apt docker rootless; do comando_falso "$c" 0; done
  export USERADD_CMD="$TMP/bin/useradd" USERDEL_CMD="$TMP/bin/userdel" LOGINCTL_CMD="$TMP/bin/loginctl" \
         SYSTEMCTL_CMD="$TMP/bin/systemctl" APT_CMD="$TMP/bin/apt" DOCKER_CMD="$TMP/bin/docker" \
         ROOTLESS_CMD="$TMP/bin/rootless"

  # Tarball falso do runner, com config.sh falso dentro; o sha256 é calculado na hora.
  local fonte="$TMP/runner-fonte"
  mkdir -p "$fonte"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "config.sh $*" >> "%s/chamadas.log"\n' "$TMP"
    printf 'exit "${CONFIG_SAIDA:-0}"\n'
  } > "$fonte/config.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fonte/run.sh"
  chmod +x "$fonte/config.sh" "$fonte/run.sh"
  export RUNNER_TARBALL="$TMP/runner-falso.tar.gz"
  tar -C "$fonte" -czf "$RUNNER_TARBALL" .
  RUNNER_SHA256="$(sha256sum "$RUNNER_TARBALL" | cut -d' ' -f1)"; export RUNNER_SHA256
  export RUNNER_VERSAO="0.0.0-falso"

  # BAIXAR_CMD <url> <destino>: em vez de rede, copia o tarball falso.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "baixar $*" >> "%s/chamadas.log"\ncp "%s" "$2"\n' "$TMP" "$RUNNER_TARBALL" > "$TMP/bin/baixar-falso"
  chmod +x "$TMP/bin/baixar-falso"
  export BAIXAR_CMD="$TMP/bin/baixar-falso"
  # CONFIG_CMD no lugar do config.sh (registro/remoção); obedece CONFIG_SAIDA. O do tarball faz o mesmo.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "config.sh $*" >> "%s/chamadas.log"\n' "$TMP"
    printf 'exit "${CONFIG_SAIDA:-0}"\n'
  } > "$TMP/bin/config-falso"
  # ARQUIVOS_DO_USUARIO_CMD <usuario>: lista arquivos do usuário fora do HOME (vazio por padrão).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/arquivos-do-usuario-falso"
  chmod +x "$TMP/bin/config-falso" "$TMP/bin/arquivos-do-usuario-falso"
  export CONFIG_CMD="$TMP/bin/config-falso" ARQUIVOS_DO_USUARIO_CMD="$TMP/bin/arquivos-do-usuario-falso"
  export SOU_ROOT=1 AGORA=1700000000
}
