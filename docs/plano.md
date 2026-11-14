# runner-vps — plano de implementação

> **Para agentes:** implemente task por task, na ordem, com os testes primeiro (veja falhar, implemente, veja passar). Um commit por parte. Marque as caixas (`- [ ]`) ao concluir.

**Goal:** `instalar.sh` instala, numa VPS Linux, um runner self-hosted do GitHub Actions para qualquer repositório ou organização, em usuário sem privilégio com Docker rootless opcional e limites de recursos, de forma idempotente e testada.

**Architecture:** um script `instalar.sh` (root, `bash -s` por SSH) com subcomandos `--so-checar`, `--status`, `--remover`; um `gancho-fim.sh` por instância; modelos de unidade e de limites embutidos no `instalar.sh` (ele viaja sozinho pelo stdin do SSH, então não pode ler arquivos ao lado); testes em bash em `testes/` que rodam o instalador contra uma "VPS" em diretório temporário, com todos os comandos com efeito substituídos por variáveis de ambiente; CI do projeto com shellcheck e os testes.

**Tech Stack:** bash, systemd (unidades de usuário, fatias), Docker rootless, GitHub Actions runner, shellcheck. Sem Python, sem bats.

**Spec:** `docs/design.md` (ela prevalece).

## Global Constraints

- Nada roda como root, na rede ou no Docker durante os testes. Cada comando com efeito tem uma variável de ambiente que o substitui; sem ela, o script usa o comando real. Lista fechada: `USERADD_CMD`, `USERDEL_CMD`, `LOGINCTL_CMD`, `SYSTEMCTL_CMD`, `APT_CMD`, `BAIXAR_CMD` (URL e destino), `ROOTLESS_CMD` (no lugar de `dockerd-rootless-setuptool.sh`), `CONFIG_CMD` (no lugar de `config.sh`), `DOCKER_CMD`, `NPROC_CMD`, `DF_CMD`, `MEMINFO_FILE`, `RAIZ` (prefixo de `/etc`, `/opt`, `/run`), `SOU_ROOT=1` (pula `id -u`), `AGORA` (epoch fixo).
- `RUNNER_TOKEN` **nunca** aparece em saída, log, arquivo, mensagem de erro ou `set -x`. Teste obrigatório em todo caminho que o recebe, inclusive quando o `CONFIG_CMD` falha.
- Nenhum nome, domínio, IP ou caminho de um repositório consumidor ou de uma VPS real em código, teste ou documento. Exemplos usam `exemplo`, `<vps>`, `<dono>/<repo>`.
- Estilo: `#!/usr/bin/env bash`, `set -euo pipefail`, função `passo()`, mensagens em português do Brasil, `VEREDITO:` no fim do diagnóstico, saída 0 em sucesso, 1 em recusa ou falha, 2 em uso errado.
- Idempotência é testada por conteúdo **e** `mtime` dos arquivos e pela ausência de `restart` no `SYSTEMCTL_CMD` falso.
- Versões baixadas têm sha256 fixo no script.
- `shellcheck -S warning` limpo em todos os `.sh`.

## Review Focus

- "Não cabe" não cria usuário, arquivo nem chama comando com efeito, mesmo com token.
- Segunda execução sem mudanças: zero arquivos alterados, zero `restart`.
- Token ausente de toda saída e de todo arquivo, nos caminhos de sucesso e de falha.
- `--remover` não apaga nada fora de `$HOME` da instância, do `.conf`, do `.slice.d` e da linha marcada em `/etc/hosts`; não apaga o usuário se houver arquivo dele fora do HOME.
- Duas instâncias na mesma VPS falsa: a segunda desconta a memória da primeira e não colide em `/etc/subuid`.
- O gancho sai com 0 mesmo com Docker falhando e nunca referencia `/var/run/docker.sock`.

## Já existe (não refazer)

- Repositório apt do Docker pronto (`configurar_repositorio_docker`, `testes/test_docker_repo.sh`). A chave é fixada pelo **fingerprint**, não pelo sha256 do arquivo: o proxy desta sessão bloqueia `download.docker.com`, então o arquivo real não pôde ser baixado para calcular um hash, e o fingerprint é a verificação que a própria documentação do Docker pede (e que sobrevive a re-armadura da chave). O arquivo baixado precisa ter exatamente uma chave primária com esse fingerprint (o apt confia em todas as chaves de um `Signed-By`); só ela é exportada para `/etc/apt/keyrings/docker.gpg`. Lista de substituições: `OS_RELEASE_FILE`, `DOCKER_APT_FINGERPRINT`, `BAIXAR_CHAVE` (testes). O `gpg` real é usado nos testes, com chaves descartáveis (a CI do GitHub o tem).
- Task 4 pronta: `gancho-fim.sh` e `testes/test_gancho.sh`. O `instalar.sh` carrega uma **cópia embutida** do gancho (função `conteudo_gancho`); o teste instala numa VPS falsa e compara o arquivo instalado com o `gancho-fim.sh` do repositório (`cmp`), então ao mudar um, regere o outro. A linha do log é `<data ISO UTC> job=<GITHUB_JOB> run=<GITHUB_RUN_ID> docker=<ok|falhou|pulado> disco=<N>G`. **Sem duração**: o design a cita, mas medi-la exige um gancho de início de job (`ACTIONS_RUNNER_HOOK_JOB_STARTED`) que o plano não prevê; fica como melhoria.
- Task 3 pronta (`instalar.sh` completo, `testes/test_instalar.sh`, `testes/test_remover_status.sh`). Decisões e desvios do texto do plano:
  - **Token pelo ambiente:** o `config.sh` recebe o token em `ACTIONS_RUNNER_INPUT_TOKEN` (o runner lê essa variável e a apaga), nunca em `--token` na linha de comando. Nos testes o `config.sh` falso grava o que viu em `$TMP/config-token-visto`, fora de `RAIZ`.
  - **Lista de substituições estendida:** além da lista fechada, `COMO_USUARIO_CMD <usuario> <comando…>` (padrão `runuser -u`), `CHOWN_CMD`, `ID_CMD` (padrão `id`) e `ARQUIVOS_DO_USUARIO_CMD`. `BAIXAR_ARQUIVO` (só nos testes) escolhe o arquivo que o `BAIXAR_CMD` falso copia.
  - **Templates embutidos** no `instalar.sh` (não existe `systemd/`), porque o script viaja sozinho pelo stdin. O `gancho-fim.sh` também é embutido (ver Task 4).
  - **`EXTRAS_SH` roda depois de ligar o serviço** (último passo), como diz o teste do plano, e não antes do `daemon-reload`.
  - **Serviço sem registro:** se o `.runner` não existe (sem `RUNNER_TOKEN`), o serviço é só habilitado (`enable`), não iniciado, para não ficar em laço de erro.
  - **Runner pinado:** v2.338.2, sha256 de x64 e arm64 calculados baixando o asset oficial da release (confira contra as notas da release se quiser). `RUNNER_VERSAO` exige `RUNNER_SHA256`. Depois de extrair, roda o `bin/installdependencies.sh` do próprio runner.
  - ~~Pendente: repositório apt do Docker~~ — resolvido depois (veja o item abaixo).
  - Usuário comum (não `--system`), com grupo próprio; `useradd` sem `-G`.
- Task 2 pronta: `instalar.sh` (argumentos, `.conf`, diagnóstico, veredito) e `testes/test_diagnostico.sh`. O `.conf` também persiste `RUNNER_NOME_GITHUB` e `EXTRAS_SHA256` (sem eles a segunda execução perderia o nome no GitHub e o sha de `EXTRAS_SH` por URL). `--status` e `--remover` saem com 1 até a Task 3. `MEMORY_MAX_MB`/`CPU_QUOTA` calculados no primeiro instalar ficam gravados no `.conf` e passam a valer como fixados (estabilidade e idempotência); apague a linha para recalcular.
- Task 1 pronta: `testes/harness.sh`, `testes/vps-falsa.sh`, `testes/rodar.sh`, `testes/test_harness.sh`, `.shellcheckrc` e `.github/workflows/ci.yml`. A VPS falsa exporta também `CONFIG_CMD` e `ARQUIVOS_DO_USUARIO_CMD`; `DF_CMD` imita `df -BG --output=avail <caminho>` (cabeçalho + `40G`); `CONFIG_SAIDA` define o código de saída do `config.sh` falso.
- `registrar.sh` (lado de quem administra) e `testes/test_registrar.sh`: geram o token pelo `gh api`, montam as linhas `export` e as enviam com o `instalar.sh` pelo stdin do SSH (`bash -s -- [subcomando]`). O teste é autossuficiente; a Task 1 pode migrá-lo para o harness, mantendo todas as asserções. O `instalar.sh` precisa honrar esse contrato: variáveis vêm do ambiente, subcomando vem de `$1`, e o stdin não é lido.
- `CLAUDE.md` e `AGENTS.md` (mesmo conteúdo): regras para agentes. Mantenha os dois iguais.

## File Structure

Criar: `instalar.sh`, `gancho-fim.sh`, `testes/harness.sh`, `testes/vps-falsa.sh`, `testes/test_diagnostico.sh`, `testes/test_instalar.sh`, `testes/test_remover_status.sh`, `testes/test_gancho.sh`, `testes/rodar.sh`, `.github/workflows/ci.yml`, `.shellcheckrc`.
Modificar: `README.md` (Task 5).

## Interfaces (como as partes se encontram)

- `instalar.sh [--so-checar | --status | --remover]`. Entrada por variáveis: obrigatórias `RUNNER_NOME` (`^[a-z0-9-]+$`) e, no primeiro `instalar`, `RUNNER_URL`; opcionais `RUNNER_TOKEN`, `RUNNER_NOME_GITHUB`, `RUNNER_ROTULOS`, `RUNNER_VERSAO`, `RUNNER_SHA256`, `DOCKER_ROOTLESS` (1), `RESERVA_MB` (1024), `MEM_MIN_MB` (2048), `DISCO_MIN_GB` (10), `MEMORY_MAX_MB`, `CPU_QUOTA`, `HOSTS_EXTRAS`, `PACOTES_EXTRAS`, `EXTRAS_SH`, `EXTRAS_SHA256`, `ENV_EXTRAS`.
- Caminhos (relativos a `RAIZ`): `/etc/runner-vps/<nome>.conf`; `/opt/runner-vps/<nome>` (HOME); `$HOME/runner/` (runner extraído, `.env`); `$HOME/bin/gancho-fim.sh`; `$HOME/.config/systemd/user/runner-vps.service`; `$HOME/runner-vps.log`; `/etc/systemd/system/user-<uid>.slice.d/runner-vps.conf`; `/etc/subuid`, `/etc/subgid`, `/etc/hosts`.
- Saída do diagnóstico: `VEREDITO: cabe (MemoryMax=<n>M CPUQuota=<n>%)` ou `VEREDITO: não cabe: <motivo>`.
- `gancho-fim.sh`: sem argumentos; lê `GITHUB_JOB`, `GITHUB_RUN_ID`, `DOCKER_HOST` (se vazio, pula o Docker); variáveis de teste `DOCKER_CMD`, `LOG_FILE`, `AGORA`, `DF_CMD`. Sempre sai com 0.
- `testes/harness.sh`: `comando_falso <nome> [codigo_saida]` cria um script em `$TMP/bin` que registra `nome args…` em `$TMP/chamadas.log` e sai com o código; `afirmar <descricao> <condicao>`; `afirmar_sem <arquivo_ou_texto> <segredo>`; `snapshot <dir>` (conteúdo + mtime); `relatorio`. `testes/vps-falsa.sh`: monta `RAIZ` com `/proc/meminfo` falso (`MEMINFO_FILE`), `df`/`nproc` falsos, um tarball falso do runner com `config.sh` falso dentro e o sha256 calculado na hora, e exporta todas as variáveis de substituição.

## Task 1: harness de testes e CI do projeto

**Files:** criar `testes/harness.sh`, `testes/vps-falsa.sh`, `testes/rodar.sh`, `.github/workflows/ci.yml`, `.shellcheckrc`.
- [x] `harness.sh` com as funções das interfaces; `rodar.sh` executa todo `testes/test_*.sh` e sai com 1 se algum falhar.
- [x] `vps-falsa.sh` com parâmetros `MEM_TOTAL_MB`, `MEM_LIVRE_MB`, `CPUS`, `DISCO_LIVRE_GB`.
- [x] Teste de fumaça do harness (dentro de `rodar.sh`): um comando falso registra a chamada e devolve o código pedido; o tarball falso confere o sha256.
- [x] `ci.yml`: em `ubuntu-latest` (este repositório é público; minutos ilimitados), `shellcheck -S warning *.sh testes/*.sh` e `testes/rodar.sh`. O `rodar.sh` precisa incluir o `testes/test_registrar.sh` que já existe.
- [x] Commit: `test: harness de testes com VPS falsa e CI com shellcheck`.

## Task 2: `instalar.sh` — argumentos, configuração e diagnóstico

**Files:** criar `instalar.sh`; criar `testes/test_diagnostico.sh`.
**Regras:** design 4.2 (configuração persistida) e 4.4 (diagnóstico e veredito).
- [x] Testes (escreva primeiro):
  1. sem `RUNNER_NOME`, ou com nome inválido (`Foo`, `a b`): saída 2 e mensagem; sem `SOU_ROOT` e `id -u` ≠ 0: saída 1 e nenhum arquivo;
  2. VPS 8192 MB total, 6144 livres, 4 CPUs, 40 GB, sem outras instâncias: `VEREDITO: cabe (MemoryMax=5120M CPUQuota=300%)`, saída 0;
  3. 2560 livres: 1536 → `não cabe: memória`, saída 1; 1 CPU: `CPUQuota=100%`; 6 GB de disco: `não cabe: disco`;
  4. outra instância com `.conf` de `MEMORY_MAX_MB=3072`: a nova desconta e, com 6144 livres, dá 2048 e cabe; com 5120 livres, não cabe;
  5. `MEMORY_MAX_MB=1024` fixado à mão: `não cabe: memória (mínimo 2048)`;
  6. `--so-checar` não cria nada em `RAIZ` e não chama nenhum comando falso com efeito;
  7. primeiro `instalar` sem `RUNNER_URL`: saída 2; com `.conf` existente e sem variáveis: usa o `.conf`; variável presente sobrescreve e o `.conf` é reescrito; o `.conf` tem `chmod 600` e **não** contém `RUNNER_TOKEN` nem a palavra `TOKEN`.
- [x] Implementar: análise de argumentos, leitura/gravação do `.conf`, diagnóstico, veredito. A instalação em si ainda não (o script para depois do veredito com uma mensagem "instalação: próxima task" que a Task 3 remove).
- [x] Commit: `feat: instalar.sh com configuração persistida, diagnóstico e veredito`.

## Task 3: `instalar.sh` — instalação, idempotência, `--status`, `--remover`

**Files:** modificar `instalar.sh` (unidade e fatia saem de funções com heredoc, não de arquivos em `systemd/`); criar `testes/test_instalar.sh`, `testes/test_remover_status.sh`.
**Regras:** design 4.2, 4.3, 4.6. Ordem: diagnóstico → usuário, `subuid`/`subgid` → pacotes → linger → rootless (se ligado; `ROOTLESS_CMD check` antes de `install`) → `PACOTES_EXTRAS` → baixar runner, sha256, extrair → registrar se `RUNNER_TOKEN` → `.env`, gancho, unidade, limites, `/etc/hosts`, `EXTRAS_SH` → `daemon-reload`, `enable --now` → veredito e estado.
- [x] Testes de instalação:
  1. em "cabe", cria todos os arquivos das interfaces; `.conf` com os valores; `.slice.d` com `MemoryMax=5120M` e `CPUQuota=300%`; `.env` com `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` e com as linhas de `ENV_EXTRAS`; unidade com `After=docker.service`;
  2. `DOCKER_ROOTLESS=0`: sem `ROOTLESS_CMD`, sem `DOCKER_HOST`, sem `After=docker.service`, sem linha em `subuid`;
  3. em "não cabe": nenhum arquivo, nenhum comando falso com efeito, mesmo com `RUNNER_TOKEN`;
  4. com `RUNNER_TOKEN`: `CONFIG_CMD` recebe `--unattended --replace --url <url> --name <nome> --labels <rótulos> --work _work` e o token; saída e todos os arquivos de `RAIZ` **sem** o token; `CONFIG_CMD` saindo com 1: script falha com mensagem sem o token e sem `set -x`;
  5. sem `RUNNER_TOKEN`: registro pulado com aviso, resto feito;
  6. segunda execução sem mudanças: `snapshot` idêntico (conteúdo e mtime), `SYSTEMCTL_CMD` sem `restart`, `/etc/hosts` e `subuid` com **uma** linha da instância; mudar `MEMORY_MAX_MB` reescreve só o `.slice.d` e o `.conf` e chama `daemon-reload`;
  7. sha256 errado: falha antes de extrair, `$HOME/runner` ausente; `ROOTLESS_CMD check` com 1: para antes do runner, com o motivo;
  8. `HOSTS_EXTRAS` acrescenta uma linha marcada `# runner-vps <nome>`; `PACOTES_EXTRAS` chega ao `APT_CMD`; `EXTRAS_SH` local é executado como último passo; `EXTRAS_SH` por URL sem `EXTRAS_SHA256`: recusa;
  9. duas instâncias: usuários, HOMEs, `.conf`, `.slice.d` e faixas de `subuid` distintos e sem colisão.
- [x] Testes de `--status` e `--remover`:
  1. `--status` imprime usuário, estado dos serviços (via `SYSTEMCTL_CMD` falso), limites e última linha do log; não altera nada;
  2. `--remover` sem token: recusa; com token: `CONFIG_CMD remove`, `SYSTEMCTL_CMD` com `disable --now`, `ROOTLESS_CMD uninstall`, apaga `$HOME`, `.conf`, `.slice.d` e a linha de `/etc/hosts`; `USERDEL_CMD` chamado só se não houver arquivo do usuário fora do HOME (simular com um arquivo em `RAIZ/var/tmp/x` pertencente ao usuário — no teste, uma lista `ARQUIVOS_DO_USUARIO_CMD` falsa); linhas de `subuid` ficam; outra instância na mesma VPS não é tocada.
- [x] Commit: `feat: instalar.sh instala usuário, Docker rootless, runner, limites e serviço; --status e --remover`.

## Task 4: `gancho-fim.sh`

**Files:** criar `gancho-fim.sh`; criar `testes/test_gancho.sh`.
**Regras:** design 4.4.
- [x] Testes:
  1. com `DOCKER_HOST` e `DOCKER_CMD compose ls -q` devolvendo `a` e `b`: chama `compose -p a down -v --remove-orphans`, idem `b`, depois `system prune -f --filter until=24h`, nessa ordem;
  2. sem `DOCKER_HOST`: nenhuma chamada ao Docker;
  3. grava uma linha em `LOG_FILE` com `AGORA`, `GITHUB_JOB`, `GITHUB_RUN_ID` e o disco livre do `DF_CMD`;
  4. `DOCKER_CMD` falhando: sai com 0 e a linha do log registra a falha;
  5. o texto do script não contém `/var/run/docker.sock` nem `sudo`.
- [x] Commit: `feat: gancho de fim de job derruba os compose do job e limpa o Docker rootless`.

## Task 5: README final

**Files:** modificar `README.md`.
- [x] Tirar o aviso "em planejamento". Passo a passo: pré-requisitos (`gh` como administrador, SSH root); `registrar.sh` como caminho principal, com os exemplos de cada subcomando, e o equivalente à mão pelo stdin do SSH; `--so-checar`, `--status`, `--remover`; tabela de todas as variáveis com padrão; a convenção do consumidor (4.5) com o trecho de YAML; operação (ver, se cair, disco cheio); limites de segurança; como rodar os testes (`testes/rodar.sh`).
- [x] Commit: `docs: README com instalação, variáveis, convenção do consumidor e operação`.

## Task 6: assistente interativo no `registrar.sh`

**Files:** modificar `registrar.sh`; criar `testes/test_assistente.sh`; modificar `README.md`.
**Regras:** design 4.6 (assistente interativo). Sem gravar nada em disco; o token nunca é perguntado.
- [x] Testes primeiro (`gh`, `ssh` e `instalar.sh` falsos, respostas pelo stdin):
  1. fluxo feliz (repositório, nome sugerido, sem avançado, confirma): teste de conexão, checagem de instância, `--so-checar`, instalação e `--status`, nessa ordem; o token só é gerado depois da confirmação;
  2. validação com repetição da pergunta: VPS (`abc`, porta inválida), chave inexistente, alvo (`a/b/c`), nome (`Ex Emplo`); valores inválidos nunca chegam ao `ssh` nem ao `gh`;
  3. conexão falhando na primeira tentativa: mensagem, pergunta de novo, segunda tentativa passa;
  4. `gh auth status` falhando: saída 1, antes de qualquer `ssh`; repositório sem permissão de administrador: recusa e pergunta de novo; organização com papel `admin`: passa e usa `orgs/<org>`;
  5. instância já existente: avisa e pergunta; "não" volta a pedir o nome; "sim" segue;
  6. avançado: valores válidos viram `MEMORY_MAX_MB`, `CPU_QUOTA`, `RUNNER_ROTULOS` e `DOCKER_ROOTLESS=0`; inválidos repetem;
  7. `--so-checar` com "não cabe": saída 1, nenhum token gerado, nada instalado;
  8. confirmação negada: saída 0, nenhum token gerado, nada instalado; EOF no meio: saída 1, nada instalado;
  9. argumentos já passados pulam as perguntas; sem argumentos e sem terminal: saída 2; `--interativo` com `--status`: saída 2;
  10. o token não aparece na saída, nos argumentos do `ssh` nem no comando equivalente impresso; o script não pergunta o token nem grava arquivo.
- [x] Implementar no `registrar.sh` (`--interativo`, ou sem argumentos num terminal), reaproveitando o próprio script para `--so-checar`, instalar e `--status`.
- [x] README: seção do assistente.
- [x] Commit: `feat: registrar.sh ganha assistente interativo que pergunta e valida antes de instalar`.

## Task 7: assistente pergunta o servidor antes do usuário e entende o `~/.ssh/config`

**Files:** modificar `registrar.sh`, `testes/test_assistente.sh`, `README.md`.
**Regras:** design 4.6 (assistente interativo, item 1). `TCP_CMD` é o comando falso do teste de porta.
- [x] Testes primeiro (atualizar as respostas do fluxo antigo, sem enfraquecer nenhuma asserção, e acrescentar):
  1. ordem: host → porta → verificação de SSH (`TCP_CMD host porta`) → usuário → chave → teste de conexão; a verificação vem antes de qualquer `ssh`;
  2. host com `@`, `:` ou começando com `-`, porta (`abc`, `0`, `70000`) e usuário (`ro ot`) inválidos repetem a pergunta e nunca chegam a `TCP_CMD` nem ao `ssh`; Enter assume porta 22 e usuário `root`; a porta 22 não aparece no comando equivalente;
  3. nada responde como SSH: mensagem, pergunta de novo host e porta, sem `ssh` para o endereço que falhou;
  4. alias do `~/.ssh/config` (`ssh -G` devolve outro `hostname`): não pergunta porta, usuário nem chave, não chama `TCP_CMD`, testa e instala com `ssh … <alias>` sem `-i` nem `-p`, e o comando equivalente usa `--vps <alias>`; alias que não conecta repete a pergunta;
  5. nome que o `ssh -G` devolve igual ao digitado (não é alias) segue o fluxo de porta e usuário;
  6. `--vps <alias>` e `--vps usuário@host:porta` passados por argumento são aceitos; `--vps 'a b'` é recusado com saída 2.
- [x] Implementar no `registrar.sh` (`TCP_CMD`; por padrão, `/dev/tcp` com `timeout` e leitura do banner).
- [x] README: assistente e `--vps <alias>`.
- [x] Commit: `feat: assistente pergunta o servidor antes do usuário e aceita Host do ~/.ssh/config`.

## Task 8: primeira pergunta do assistente: Host salvo do `~/.ssh/config` ou IP

**Files:** modificar `registrar.sh`, `testes/test_assistente.sh`, `README.md`.
**Regras:** design 4.6 (assistente interativo, item 1). `SSH_CONFIG_FILE` é a variável só de teste (padrão `$HOME/.ssh/config`); os testes nunca leem o config real.
- [x] Testes primeiro:
  1. config com Hosts concretos: a pergunta "como conectar" aparece, Enter escolhe "Host salvo", a lista é numerada e mostra `usuário@hostname:porta` de cada um (via `ssh -G` falso); escolher um número usa aquele alias, sem perguntar porta, usuário nem chave, sem `TCP_CMD`; o `ssh` e o comando equivalente usam o alias;
  2. a lista ignora curingas (`*`, `?`, `!`), comentários e `Match`, junta vários nomes de uma mesma linha `Host`, não repete nomes e aceita `Host` em qualquer caixa;
  3. número inválido (`0`, acima do total, texto, vazio) repete só a escolha;
  4. escolher "IP ou nome" segue o fluxo de host, porta, SSH, usuário e chave;
  5. sem `~/.ssh/config`, ou só com `Host *`: a pergunta não aparece e o fluxo vai direto ao IP;
  6. `--vps` por argumento pula a pergunta mesmo com Hosts no config; resposta inválida à pergunta repete.
- [x] Implementar no `registrar.sh`.
- [x] README: assistente (primeira pergunta).
- [x] Commit: `feat: assistente começa perguntando se usa um Host do ~/.ssh/config ou um IP`.

## Task 9: painel de decisão no `--so-checar` e no assistente

**Files:** modificar `instalar.sh`, `registrar.sh`, `testes/vps-falsa.sh`, `testes/test_assistente.sh`, `README.md`; criar `testes/test_painel.sh`.
**Regras:** design 4.4 (diagnóstico e painel). Somente leitura. Variáveis só de teste novas: `UNAME_CMD`, `LOADAVG_FILE`, `USERNS_FILE`, `APPARMOR_USERNS_FILE`.
- [ ] Testes primeiro (`testes/test_painel.sh`, VPS falsa):
  1. VPS nova: as seções Sistema, Docker rootless, Instâncias nesta VPS, Esta instância, Avisos e Recursos e veredito aparecem, nessa ordem, com distribuição, arquitetura, kernel, systemd, apt, carga, memória, swap, CPUs e disco; "instalação nova"; `VEREDITO: cabe` por último; saída 0;
  2. somente leitura: o `snapshot` de `RAIZ` não muda, nenhum comando com efeito é chamado (só `systemctl is-active`), e o `RUNNER_TOKEN` do ambiente não aparece na saída nem no erro;
  3. instância já instalada: "já instalada", usuário com uid, serviço, `.runner` presente, URL configurada; com duas instâncias, ambas listadas com `MemoryMax`, `CPUQuota` e serviço, a atual marcada "(esta)" e o total reservado;
  4. Docker: instalado ou não, repositório apt configurado ou não, `max_user_namespaces` (ok, 0, ausente = desconhecido), `newuidmap`; `DOCKER_ROOTLESS=0` mostra "desligado" e não consulta nada do rootless;
  5. "não cabe" mostra o painel completo e sai com 1: memória, systemd ausente, `apt-get` ausente, user namespaces desligados com rootless; user namespaces desligados com `DOCKER_ROOTLESS=0` e `max_user_namespaces` ausente: cabe;
  6. avisos: URL configurada diferente da informada; AppArmor restringindo user namespaces com rootless ligado; sem divergência e sem restrição: "nenhum";
  7. a instalação também recusa quando o veredito é "não cabe" por um dos motivos novos, sem criar nada.
- [ ] Testes do assistente: o `--so-checar` chamado pelo assistente leva `RUNNER_URL` do alvo e nunca `RUNNER_TOKEN`; o título é "Painel da VPS"; "não cabe" ainda para antes de gerar token.
- [ ] Implementar `painel()` no `instalar.sh` e os novos motivos no `diagnostico()`; o assistente passa o alvo ao `--so-checar`.
- [ ] README: painel.
- [ ] Commit: `feat: --so-checar vira painel de decisão (sistema, Docker, instâncias, estado, avisos) e o assistente o mostra antes de confirmar`.

## Fecho

- [x] `shellcheck` limpo e `testes/rodar.sh` verde, local e no CI do projeto.
- [x] Nenhum nome, domínio, IP ou caminho de VPS ou repositório real em nenhum arquivo (`git grep -nE '[0-9]{1,3}(\.[0-9]{1,3}){3}'` só pode achar `127.0.0.1`).
- [ ] Tag `v0.1.0` depois da primeira instalação real bem-sucedida.
