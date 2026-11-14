#!/usr/bin/env bash
# Testes do assistente interativo do registrar.sh (registrar.sh --interativo), com gh, ssh e
# instalar.sh falsos e as respostas pelo stdin. Sem rede, sem root, sem terminal.
set -uo pipefail

aqui="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=testes/harness.sh
source "$aqui/harness.sh"
script="$aqui/../registrar.sh"

TOKEN_FALSO="AAAATOKENSECRETO123456"
export TOKEN_FALSO

# gh falso: o comportamento vem de arquivos em $TMP/ctl (um valor por arquivo).
cat > "$TMP/bin/gh" <<'CORPO'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$TMP/chamadas.log"
ctl="$TMP/ctl"
case "$1 $2" in
  "auth status") exit "$(cat "$ctl/gh_auth" 2> /dev/null || echo 0)" ;;
esac
case "$*" in
  *permissions.admin*) cat "$ctl/gh_admin" 2> /dev/null || echo true; exit 0 ;;
  *memberships/orgs*) cat "$ctl/gh_papel" 2> /dev/null || echo admin; exit 0 ;;
  *registration-token*) printf '%s\n' "$TOKEN_FALSO"; exit 0 ;;
esac
exit 0
CORPO

# ssh falso: distingue o teste de conexão, a checagem de instância e o `bash -s`.
cat > "$TMP/bin/ssh" <<'CORPO'
#!/usr/bin/env bash
ctl="$TMP/ctl"
tudo="$*"   # (${*##…} cortaria cada parâmetro em separado)
printf 'ssh %s\n' "$tudo" >> "$TMP/chamadas.log"
case "$tudo" in
  *"bash -s -- "*)
    modo="${tudo##*bash -s -- }"
    cat > "$TMP/stdin.$(date +%s%N)"
    case "$modo" in
      --so-checar)
        if [ "$(cat "$ctl/cabe" 2> /dev/null || echo 0)" = 0 ]; then
          echo 'VEREDITO: cabe (MemoryMax=4096M CPUQuota=200%)'; exit 0
        fi
        echo 'VEREDITO: não cabe: memória'; exit 1 ;;
      --status) echo 'ESTADO FALSO'; exit 0 ;;
      *) echo 'INSTALADO'; exit "$(cat "$ctl/instalar" 2> /dev/null || echo 0)" ;;
    esac ;;
  *"test -e /etc/runner-vps/"*)
    n="${tudo##*/etc/runner-vps/}"; n="${n%.conf}"
    if grep -qx -- "$n" "$ctl/existentes" 2> /dev/null; then exit 0; fi
    exit 1 ;;
  *)
    # teste de conexão: falha as N primeiras vezes se $ctl/falhas_conexao existir
    f="$ctl/falhas_conexao"
    if [ -s "$f" ] && [ "$(cat "$f")" -gt 0 ]; then echo $(( $(cat "$f") - 1 )) > "$f"; exit 255; fi
    exit 0 ;;
esac
CORPO
printf '#!/usr/bin/env bash\necho INSTALADOR FALSO "$@"\n' > "$TMP/instalar.sh"
chmod +x "$TMP/bin/gh" "$TMP/bin/ssh"
: > "$TMP/chave"   # uma "chave" que existe

export GH_CMD="$TMP/bin/gh" SSH_CMD="$TMP/bin/ssh" INSTALAR_SH="$TMP/instalar.sh"

novo_cenario() {
  rm -rf "$TMP/ctl" "$TMP/out" "$TMP/err" "$TMP"/stdin.*
  mkdir -p "$TMP/ctl"; : > "$TMP/chamadas.log"
}
# assistente <respostas…> [-- argumentos…]: uma resposta por linha no stdin; devolve o código.
assistente() {
  local resp=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do resp+=("$1"); shift; done
  [ "${1:-}" != -- ] || shift
  args=("$@")
  printf '%s\n' "${resp[@]}" | bash "$script" --interativo "${args[@]}" > "$TMP/out" 2> "$TMP/err"
  echo $?
}
# número da linha da primeira chamada que casa com o padrão (0 se não houver)
linha_de() { grep -nE -- "$1" "$TMP/chamadas.log" | head -n 1 | cut -d: -f1 | grep . || echo 0; }
houve() { grep -qE -- "$1" "$TMP/chamadas.log"; }
saida_tem() { grep -qF -- "$1" "$TMP/out" "$TMP/err"; }
PADRAO_INSTALAR='bash -s -- *$'   # `bash -s -- ` sem subcomando = instalação
instalou() { houve "$PADRAO_INSTALAR"; }
inst_stdin() { grep -l RUNNER_TOKEN "$TMP"/stdin.* 2> /dev/null | head -n 1; }   # o que foi enviado na instalação
gerou_token() { houve 'registration-token'; }

echo "assistente interativo"

# 1. fluxo feliz
novo_cenario
codigo="$(assistente root@vps.exemplo:2222 "$TMP/chave" dono/meu-repo '' n s)"
afirmar "fluxo feliz sai com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "testa a conexão com -i, -p e BatchMode" \
  "$(houve "ssh .*-i $TMP/chave -p 2222 .*BatchMode=yes.* root@vps.exemplo true"; echo $?)"
afirmar "checa a instância sugerida (nome derivado do repositório)" "$(houve 'test -e /etc/runner-vps/meu-repo.conf'; echo $?)"
afirmar "roda o --so-checar" "$(houve 'bash -s -- --so-checar'; echo $?)"
afirmar "instala depois do diagnóstico" \
  "$([ "$(linha_de 'bash -s -- --so-checar')" -gt 0 ] && [ "$(linha_de "$PADRAO_INSTALAR")" -gt "$(linha_de 'bash -s -- --so-checar')" ] && echo 0 || echo 1)"
afirmar "mostra o --status no fim" "$([ "$(linha_de 'bash -s -- --status')" -gt "$(linha_de "$PADRAO_INSTALAR")" ] && echo 0 || echo 1)"
afirmar "o token é gerado só depois do diagnóstico" \
  "$([ "$(linha_de registration-token)" -gt "$(linha_de 'bash -s -- --so-checar')" ] && echo 0 || echo 1)"
afirmar "a instalação leva RUNNER_URL e RUNNER_NOME" \
  "$(grep -q 'export RUNNER_URL=https://github.com/dono/meu-repo' "$(inst_stdin)" && grep -q 'export RUNNER_NOME=meu-repo' "$(inst_stdin)"; echo $?)"
afirmar "imprime o comando equivalente sem o assistente" "$(saida_tem './registrar.sh --vps root@vps.exemplo:2222'; echo $?)"
# (afirmar_sem já registra o resultado; não pode rodar dentro de $(...))
afirmar_sem "$TMP/out" "$TOKEN_FALSO"
afirmar_sem "$TMP/err" "$TOKEN_FALSO"
afirmar_sem "$TMP/chamadas.log" "$TOKEN_FALSO"
afirmar "o token foi mesmo enviado na instalação (a ausência acima não é por acaso)" "$(grep -q "export RUNNER_TOKEN=$TOKEN_FALSO" "$(inst_stdin)"; echo $?)"

# 2. validação com repetição: nada inválido chega ao ssh ou ao gh
novo_cenario
codigo="$(assistente abc 'root@vps:xx' 'root@vps.exemplo' '' dono/a/b dono/repo 'Ex Emplo' exemplo n s)"
afirmar "respostas inválidas repetem a pergunta e o fluxo termina com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "VPS inválida não chegou ao ssh" "$(! houve 'ssh .*(abc|vps:xx|:xx)'; echo $?)"
afirmar "alvo inválido não chegou ao gh" "$(! houve 'gh .*a/b/c|gh .*dono/a/b'; echo $?)"
afirmar "nome inválido não chegou ao ssh" "$(! houve 'Ex Emplo'; echo $?)"
afirmar "usa a resposta válida (nome exemplo)" "$(houve 'test -e /etc/runner-vps/exemplo.conf'; echo $?)"

# 3. chave inexistente repete; existente vira -i
novo_cenario
codigo="$(assistente root@vps.exemplo "$TMP/nao-existe" "$TMP/chave" dono/repo '' n s)"
afirmar "chave inexistente repete a pergunta" "$([ "$codigo" = 0 ] && ! houve "nao-existe" && houve "ssh -i $TMP/chave" && echo 0 || echo 1)"

# 4. conexão falhando na primeira tentativa
novo_cenario
echo 1 > "$TMP/ctl/falhas_conexao"
codigo="$(assistente root@vps.exemplo '' root@vps.exemplo '' dono/repo '' n s)"
afirmar "conexão que falha: mensagem, nova tentativa e sucesso" \
  "$([ "$codigo" = 0 ] && saida_tem 'não consegui conectar' && [ "$(grep -c ' true$' "$TMP/chamadas.log")" -ge 2 ] && echo 0 || echo 1)"

# 5. gh e permissões
novo_cenario
echo 1 > "$TMP/ctl/gh_auth"
codigo="$(assistente root@vps.exemplo '' dono/repo '' n s)"
afirmar "gh não autenticado: saída 1, antes de qualquer ssh, sem instalar nem gerar token" "$([ "$codigo" = 1 ] && ! houve '^ssh' && ! instalou && ! gerou_token && echo 0 || echo 1)"
afirmar "gh não autenticado: orienta gh auth login" "$(saida_tem 'gh auth login'; echo $?)"

novo_cenario
echo false > "$TMP/ctl/gh_admin"
codigo="$(assistente root@vps.exemplo '' dono/repo)"
afirmar "sem permissão de administrador: recusa (EOF depois) e não instala" "$([ "$codigo" != 0 ] && saida_tem 'administrador' && ! instalou && echo 0 || echo 1)"

novo_cenario
codigo="$(assistente root@vps.exemplo '' minha-org '' n s)"
afirmar "organização com papel admin: passa e usa orgs/<org>" \
  "$([ "$codigo" = 0 ] && houve 'gh api user/memberships/orgs/minha-org' && houve 'orgs/minha-org/actions/runners/registration-token' && echo 0 || echo 1)"
afirmar "RUNNER_URL da organização" "$(grep -q 'export RUNNER_URL=https://github.com/minha-org' "$(inst_stdin)"; echo $?)"

# 6. instância já existente (o nome sugerido é "repo")
novo_cenario
echo repo > "$TMP/ctl/existentes"
codigo="$(assistente root@vps.exemplo '' dono/repo '' n outro n s)"
afirmar "instância existente: avisa e, respondendo não, pede outro nome" \
  "$([ "$codigo" = 0 ] && saida_tem 'Já existe' && houve 'test -e /etc/runner-vps/outro.conf' && echo 0 || echo 1)"
afirmar "instância existente: segue com o nome novo" "$(grep -q 'export RUNNER_NOME=outro' "$(inst_stdin)"; echo $?)"
novo_cenario
echo repo > "$TMP/ctl/existentes"
codigo="$(assistente root@vps.exemplo '' dono/repo '' s n s)"
afirmar "instância existente: respondendo sim, segue com o mesmo nome" \
  "$([ "$codigo" = 0 ] && instalou && grep -q 'export RUNNER_NOME=repo' "$(inst_stdin)" && echo 0 || echo 1)"

# 7. opções avançadas
novo_cenario
codigo="$(assistente root@vps.exemplo '' dono/repo '' s abc 3072 'x%' 150 'a b' ci,gpu n s)"
afirmar "avançado com valores válidos termina com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
instalacao="$(inst_stdin)"
afirmar "MEMORY_MAX_MB, CPU_QUOTA, rótulos e DOCKER_ROOTLESS=0 vão para a instalação" \
  "$(grep -q 'export MEMORY_MAX_MB=3072' "$instalacao" && grep -q 'export CPU_QUOTA=150' "$instalacao" \
     && grep -q 'export RUNNER_ROTULOS=ci\\,gpu' "$instalacao" && grep -q 'export DOCKER_ROOTLESS=0' "$instalacao"; echo $?)"
afirmar "valores inválidos (abc, x%, 'a b') repetiram a pergunta" "$(! grep -qE 'MEMORY_MAX_MB=abc|CPU_QUOTA=x|ROTULOS=a\\ b' "$instalacao"; echo $?)"

# 8. diagnóstico "não cabe"
novo_cenario
echo 1 > "$TMP/ctl/cabe"
codigo="$(assistente root@vps.exemplo '' dono/repo '' n s)"
afirmar "não cabe: saída 1" "$([ "$codigo" = 1 ] && echo 0 || echo 1)"
afirmar "não cabe: nada instalado e nenhum token gerado" "$(! instalou && ! gerou_token && echo 0 || echo 1)"
afirmar "não cabe: mostra o veredito" "$(saida_tem 'VEREDITO: não cabe'; echo $?)"

# 9. confirmação negada e EOF
novo_cenario
codigo="$(assistente root@vps.exemplo '' dono/repo '' n n)"
afirmar "confirmação negada: saída 0, sem token e sem instalar" "$([ "$codigo" = 0 ] && ! instalou && ! gerou_token && echo 0 || echo 1)"
afirmar "confirmação negada: avisa que nada foi instalado" "$(saida_tem 'Nada foi instalado'; echo $?)"
novo_cenario
codigo="$(assistente root@vps.exemplo)"
afirmar "EOF no meio: saída 1, sem token e sem instalar" "$([ "$codigo" = 1 ] && ! instalou && ! gerou_token && echo 0 || echo 1)"

# 10. instalação falhando: saída 1 e sem comando equivalente de sucesso
novo_cenario
echo 1 > "$TMP/ctl/instalar"
codigo="$(assistente root@vps.exemplo '' dono/repo '' n s)"
afirmar "instalação falhando: saída 1" "$([ "$codigo" = 1 ] && echo 0 || echo 1)"

# 11. argumentos já passados pulam as perguntas
novo_cenario
codigo="$(assistente n s -- --vps root@vps.exemplo --repo dono/repo --nome exemplo)"
afirmar "com --vps, --repo e --nome só pergunta o avançado e a confirmação" \
  "$([ "$codigo" = 0 ] && instalou && echo 0 || echo 1)"

# 12. uso sem argumentos e sem terminal; --interativo com outros modos
novo_cenario
bash "$script" < /dev/null > "$TMP/out" 2> "$TMP/err"; codigo=$?
afirmar "sem argumentos e sem terminal: saída 2 e nada chamado" "$([ "$codigo" = 2 ] && [ ! -s "$TMP/chamadas.log" ] && echo 0 || echo 1)"
for m in --status --so-checar --remover --sem-token; do
  novo_cenario
  bash "$script" --interativo "$m" --vps root@v --nome exemplo < /dev/null > "$TMP/out" 2> "$TMP/err"; codigo=$?
  afirmar "--interativo com $m: saída 2 e nada chamado" "$([ "$codigo" = 2 ] && [ ! -s "$TMP/chamadas.log" ] && echo 0 || echo 1)"
done

# 13. o script não lê o token do teclado e o assistente não grava nada em disco
afirmar "registrar.sh não lê o token do teclado" "$(! grep -nE 'read .*(token|TOKEN)' "$script"; echo $?)"
novo_cenario
mkdir -p "$TMP/casa" "$TMP/cwd"
codigo="$(cd "$TMP/cwd" && printf '%s\n' root@vps.exemplo '' dono/repo '' n s | HOME="$TMP/casa" bash "$script" --interativo > "$TMP/out" 2> "$TMP/err"; echo $?)"
afirmar "execução completa do assistente sai com 0" "$([ "$codigo" = 0 ] && echo 0 || echo 1)"
afirmar "não deixou arquivo no HOME nem no diretório atual" "$([ -z "$(find "$TMP/casa" "$TMP/cwd" -type f)" ] && echo 0 || echo 1)"

relatorio "assistente interativo"
