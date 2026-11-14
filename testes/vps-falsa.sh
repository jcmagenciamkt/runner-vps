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
  for c in apt docker rootless chown; do comando_falso "$c" 0; done
  # usuários falsos: useradd cria o HOME e um registro com o uid (2001, 2002…); id e userdel leem/apagam o registro.
  mkdir -p "$TMP/usuarios"; printf '2001\n' > "$TMP/proximo-uid"
  cat > "$TMP/bin/useradd" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "useradd $*" >> "$TMP/chamadas.log"
home=""; nome=""
while [ "$#" -gt 0 ]; do
  case "$1" in --home-dir|-d) home="$2"; shift ;; -*) ;; *) nome="$1" ;; esac
  shift
done
uid="$(cat "$TMP/proximo-uid")"; printf '%s\n' "$((uid + 1))" > "$TMP/proximo-uid"
mkdir -p "$home"; printf '%s\n' "$uid" > "$TMP/usuarios/$nome"
FALSO
  cat > "$TMP/bin/id-falso" <<'FALSO'
#!/usr/bin/env bash
# id -u <usuario>
[ -f "$TMP/usuarios/$2" ] && cat "$TMP/usuarios/$2" || { echo "id: '$2': no such user" >&2; exit 1; }
FALSO
  cat > "$TMP/bin/userdel" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "userdel $*" >> "$TMP/chamadas.log"
rm -f "$TMP/usuarios/${!#}"
FALSO
  cat > "$TMP/bin/loginctl" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "loginctl $*" >> "$TMP/chamadas.log"
if [ "${1:-}" = enable-linger ]; then mkdir -p "$RAIZ/var/lib/systemd/linger"; : > "$RAIZ/var/lib/systemd/linger/$2"; fi
if [ "${1:-}" = disable-linger ]; then rm -f "$RAIZ/var/lib/systemd/linger/$2"; fi
FALSO
  cat > "$TMP/bin/systemctl" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "systemctl $*" >> "$TMP/chamadas.log"
case " $* " in *" is-active "*) echo active ;; esac
exit "${SYSTEMCTL_SAIDA:-0}"
FALSO
  # COMO_USUARIO_CMD <usuario> <comando…>: nos testes não troca de usuário; só registra e executa.
  cat > "$TMP/bin/como-usuario" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "como-usuario $*" >> "$TMP/chamadas.log"
shift
exec "$@"
FALSO
  # ARQUIVOS_DO_USUARIO_CMD <usuario>: lista arquivos do usuário fora do HOME (vazio por padrão).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/arquivos-do-usuario-falso"
  chmod +x "$TMP/bin/useradd" "$TMP/bin/id-falso" "$TMP/bin/userdel" "$TMP/bin/loginctl" "$TMP/bin/systemctl" \
    "$TMP/bin/como-usuario" "$TMP/bin/arquivos-do-usuario-falso"
  export USERADD_CMD="$TMP/bin/useradd" USERDEL_CMD="$TMP/bin/userdel" LOGINCTL_CMD="$TMP/bin/loginctl" \
         SYSTEMCTL_CMD="$TMP/bin/systemctl" APT_CMD="$TMP/bin/apt" DOCKER_CMD="$TMP/bin/docker" \
         ROOTLESS_CMD="$TMP/bin/rootless" COMO_USUARIO_CMD="$TMP/bin/como-usuario" CHOWN_CMD="$TMP/bin/chown" \
         ID_CMD="$TMP/bin/id-falso" ARQUIVOS_DO_USUARIO_CMD="$TMP/bin/arquivos-do-usuario-falso"

  # config.sh falso (serve de CONFIG_CMD e vai dentro do tarball). Registra os argumentos, guarda o token que
  # recebeu pelo ambiente em $TMP/config-token-visto (fora de RAIZ), cria/remove .runner no diretório do runner.
  cat > "$TMP/bin/config-falso" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "config.sh $*" >> "$TMP/chamadas.log"
printf '%s\n' "${ACTIONS_RUNNER_INPUT_TOKEN:-}" > "$TMP/config-token-visto"
codigo="${CONFIG_SAIDA:-0}"
if [ "$codigo" = 0 ] && [ -e ./run.sh ]; then
  if [ "${1:-}" = remove ]; then rm -f .runner .credentials; else : > .runner; fi
fi
exit "$codigo"
FALSO
  chmod +x "$TMP/bin/config-falso"
  export CONFIG_CMD="$TMP/bin/config-falso"

  # Tarball falso do runner, com config.sh e run.sh falsos dentro; o sha256 é calculado na hora.
  local fonte="$TMP/runner-fonte"
  mkdir -p "$fonte"
  cp "$TMP/bin/config-falso" "$fonte/config.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fonte/run.sh"
  mkdir -p "$fonte/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "installdependencies" >> "$TMP/chamadas.log"\n' > "$fonte/bin/installdependencies.sh"
  chmod +x "$fonte/config.sh" "$fonte/run.sh" "$fonte/bin/installdependencies.sh"
  export RUNNER_TARBALL="$TMP/runner-falso.tar.gz"
  tar -C "$fonte" -czf "$RUNNER_TARBALL" .
  RUNNER_SHA256="$(sha256sum "$RUNNER_TARBALL" | cut -d' ' -f1)"; export RUNNER_SHA256
  export RUNNER_VERSAO="0.0.0-falso"

  # BAIXAR_CMD <url> <destino>: em vez de rede, copia o tarball falso (ou $BAIXAR_ARQUIVO, se definido).
  cat > "$TMP/bin/baixar-falso" <<'FALSO'
#!/usr/bin/env bash
printf '%s\n' "baixar $*" >> "$TMP/chamadas.log"
cp "${BAIXAR_ARQUIVO:-$RUNNER_TARBALL}" "$2"
FALSO
  chmod +x "$TMP/bin/baixar-falso"
  export BAIXAR_CMD="$TMP/bin/baixar-falso"
  export SOU_ROOT=1 AGORA=1700000000
}

# nova_vps: recomeça do zero (RAIZ, comandos falsos, registro de chamadas), com os parâmetros do ambiente.
nova_vps() {
  rm -rf "${TMP:?}/raiz" "${TMP:?}/runner-fonte" "${TMP:?}/usuarios"
  : > "$TMP/chamadas.log"
  montar_vps_falsa
}
