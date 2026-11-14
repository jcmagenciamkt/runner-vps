# runner-vps — design

**Data:** 13/11/2026 · **Situação:** proposta, esperando aprovação do dono do repositório.
**Origem:** os minutos do GitHub Actions do plano gratuito acabam antes do fim do mês em repositórios privados com CI pesado, e os jobs param de iniciar. A solução é um runner self-hosted numa VPS que já existe. Este projeto é **agnóstico**: não sabe nada do repositório que vai usar nem da VPS; tudo o que é específico entra por variável de ambiente ou por um script de extras. Itens marcados **(minha decisão)** foram escolhidos por quem escreveu e podem ser trocados.
**Caminhos descartados** (para não serem reabertos sem motivo): *dar ao runner o socket do Docker de root*, porque equivale a root na VPS para qualquer PR; *runner efêmero com PAT ou GitHub App na VPS*, porque troca um risco por outro maior; *serviço de sistema via `svc.sh`*, porque ficaria fora da fatia do usuário e os limites não valeriam para o Docker rootless.

## 1. Por que e o que é sucesso
- O plano gratuito dá 2.000 minutos por mês em repositório privado. Um CI com back-end, front-end e testes de navegador gasta de 30 a 50 minutos por PR, e jobs pulados ainda cobram cerca de 1 minuto. Com agentes abrindo PRs automaticamente, os minutos acabam no meio do mês e nenhum PR pode ser mergeado.
- **Sucesso:**
  - os jobs rodam na VPS e não consomem minutos do plano;
  - o dono do repositório **liga e desliga** o uso do runner por uma variável do repositório, sem PR;
  - o resto da VPS (sites, bancos, outros serviços) não fica lento nem para por causa do CI: os limites de memória e CPU são fixos e calculados antes de instalar;
  - um PR malicioso não lê arquivos fora do usuário do runner, não fala com o Docker de root e não alcança os contêineres de outros projetos;
  - nenhum token do GitHub fica gravado na VPS; o token de registro é de uso único;
  - rodar o instalador de novo não muda nada se nada mudou; remover desfaz tudo.

## 2. Objetivos, fora do escopo e o que seria um fracasso
- **Objetivos:** `instalar.sh` (root, idempotente, enviado por `ssh … 'bash -s'`), com diagnóstico "cabe / não cabe", `--so-checar`, `--status` e `--remover`; usuário por instância; Docker rootless opcional; limites na fatia do usuário; gancho de limpeza ao fim de cada job; configuração persistida em `/etc/runner-vps/<nome>.conf`; testes sem rede, sem Docker e sem root; CI do próprio projeto (shellcheck e testes); documentação de uso e de volta atrás.
- **Fora do escopo:** runner efêmero; runner em contêiner; mais de um job por vez na mesma instância; aviso (Telegram, e-mail) quando o runner cai; runner no Windows ou macOS; mudanças nos workflows dos repositórios consumidores além da convenção da seção 4.5; firewall de entrada (o runner só faz conexões de saída).
- **Seria um fracasso:** o job de um PR chegar a `/var/run/docker.sock`, a arquivos de outros usuários ou à rede Docker de outro projeto; o CI derrubar um serviço da VPS por falta de memória; o instalador deixar a VPS pela metade quando falha; um token aparecer em log, arquivo ou saída; o dono precisar de PR para voltar aos runners do GitHub.

## 3. Restrições
- VPS Linux com systemd, Ubuntu LTS ou Debian **(minha decisão: só `apt`)**, acesso root por SSH. O instalador roda como root, mas tudo o que o runner faz roda como o usuário da instância.
- Os jobs podem precisar de Docker (`services:` e `docker compose`). O Docker rootless atende: namespace de rede próprio, portas publicadas acima de 1024 no `127.0.0.1` da VPS, sem acesso às redes do Docker de root. Exige `user namespaces` no kernel, `uidmap`, `dbus-user-session`, `slirp4netns` (ou `pasta`) e faixas em `/etc/subuid` e `/etc/subgid`.
- Em `pull_request`, o GitHub executa o workflow da branch do PR. Quem tem escrita no repositório pode mudar o workflow e rodar qualquer comando no runner. Este projeto **não resolve isso**; ele reduz o que o runner tem e alcança. Repositórios públicos que aceitam PR de desconhecidos precisam da aprovação manual do GitHub ("Require approval for all outside collaborators") ou não devem usar isto.
- Um runner self-hosted executa um job por vez. Mais paralelismo = mais instâncias.
- O token de registro vem de *Settings → Actions → Runners → New self-hosted runner* (repositório ou organização), vale 1 hora e é de uso único. O instalador o recebe por variável, usa uma vez e não grava. `--remover` precisa de um token novo.
- O runner se atualiza sozinho; o GitHub recusa runners com mais de 30 dias de atraso. A versão inicial é fixada por sha256 só para a integridade do download **(minha decisão)**.
- Nada do repositório consumidor (nomes, domínios, IPs) entra neste projeto. O que é específico entra por `HOSTS_EXTRAS`, `PACOTES_EXTRAS` e `EXTRAS_SH`.

## 4. Como funciona

### 4.1 Visão geral
```
GitHub: workflow lê a variável CI_RUNS_ON
   ["self-hosted","linux","<rótulo>"]  → fila da instância na VPS
   "ubuntu-latest" ou ausente           → runner do GitHub (como antes)

VPS, por instância <nome>:
   usuário runner-<nome> (sem sudo, sem grupo docker), linger ligado
   systemd --user: runner-vps.service (run.sh) + docker.service (rootless, opcional)
   limites em /etc/systemd/system/user-<uid>.slice.d/runner-vps.conf
   /opt/runner-vps/<nome>/runner/_work: checkout e artefatos do job
   /etc/runner-vps/<nome>.conf: configuração da instância (sem token)
   gancho ao fim de cada job: derruba os compose do job, prune, uma linha no log
```

### 4.2 Instância, usuário e runner
- **Instância** = `RUNNER_NOME` (obrigatório; `[a-z0-9-]+`). Define o usuário `runner-<nome>`, o HOME `/opt/runner-vps/<nome>`, a configuração `/etc/runner-vps/<nome>.conf` e o nome do runner no GitHub (`RUNNER_NOME`, ou `RUNNER_NOME_GITHUB` se quiser outro). Várias instâncias convivem na mesma VPS; cada uma com Docker, limites e log próprios.
- Usuário de sistema, shell `bash`, **sem** `sudo`, **sem** o grupo `docker`, sem chave SSH. O dono administra com `sudo -u runner-<nome>` e `systemctl --user -M runner-<nome>@`.
- `loginctl enable-linger`, para o `systemd --user` existir sem sessão.
- Runner do GitHub em `$HOME/runner`, versão e sha256 fixos no script (`RUNNER_VERSAO`, `RUNNER_SHA256`, sobrescrevíveis). Registro: `config.sh --unattended --replace --url $RUNNER_URL --name <nome> --labels <rótulos> --work _work`, com o token em `RUNNER_TOKEN`. `--replace` permite reinstalar com o mesmo nome. O instalador **não ecoa** o token, não usa `set -x` e nunca o grava. Ele o entrega ao `config.sh` pela variável `ACTIONS_RUNNER_INPUT_TOKEN`, só durante a chamada, e nunca em `--token` na linha de comando (`ps`).
- `RUNNER_URL` aceita repositório (`https://github.com/<dono>/<repo>`) ou organização (`https://github.com/<org>`). `RUNNER_ROTULOS` padrão = `<nome>`; o GitHub acrescenta `self-hosted`, `Linux` e a arquitetura.
- Runner **persistente** **(minha decisão)**: cada job começa com o checkout limpando o `_work`, e o gancho (4.4) remove o que sobrou no Docker.
- Unidade de usuário `runner-vps.service` em `$HOME/.config/systemd/user/`: `ExecStart=$HOME/runner/run.sh`, `Restart=always`, `RestartSec=10`, `After=docker.service` quando o rootless estiver ligado, habilitada em `default.target`.
- `$HOME/runner/.env` (o runner repassa aos jobs): `DOCKER_HOST=unix:///run/user/<uid>/docker.sock` (se rootless), `PATH` com `$HOME/.local/bin` na frente, e as linhas de `ENV_EXTRAS` (`CHAVE=valor`, separadas por `;`), para o repositório consumidor apontar o que precisar (por exemplo, o caminho de um navegador).
- Configuração persistida em `/etc/runner-vps/<nome>.conf` (`chmod 600`, root): `RUNNER_URL`, `RUNNER_ROTULOS`, `DOCKER_ROOTLESS`, `MEM_MIN_MB`, `DISCO_MIN_GB`, `RESERVA_MB`, `HOSTS_EXTRAS`, `PACOTES_EXTRAS`, `EXTRAS_SH`, `ENV_EXTRAS`, `MEMORY_MAX_MB`, `CPU_QUOTA`. Na primeira execução vem das variáveis; nas seguintes, o arquivo é a fonte e as variáveis presentes o sobrescrevem. **Nunca** contém `RUNNER_TOKEN`.

### 4.3 Docker rootless (opcional, `DOCKER_ROOTLESS=1` por padrão)
- Como root: pacotes `docker-ce`, `docker-ce-rootless-extras`, `docker-compose-plugin`, `uidmap`, `dbus-user-session`, `slirp4netns` (do repositório oficial do Docker, se ainda não houver Docker; se houver, só os que faltam); o instalador configura o repositório apt oficial (Debian e Ubuntu, formato deb822 em `/etc/apt/sources.list.d/docker.sources`) só se não houver nenhum configurado e o `dockerd-rootless-setuptool.sh` não existir; a chave é fixada pelo **fingerprint** (`9DC858229FC7DD38854AE2D88D81803C0EBFCD88`, o da documentação do Docker): o arquivo baixado precisa ter exatamente uma chave primária com esse fingerprint, e só ela vai para `/etc/apt/keyrings/docker.gpg`; uma linha em `/etc/subuid` e `/etc/subgid` para o usuário (faixa de 65536, escolhida sem colidir com as existentes).
- Como o usuário: `dockerd-rootless-setuptool.sh install` e `systemctl --user enable --now docker`. Dados em `$HOME/.local/share/docker`.
- Se `dockerd-rootless-setuptool.sh check` falhar, o instalador **para, com o motivo**, e não instala o runner. Não existe fallback para o socket de root.
- Com `DOCKER_ROOTLESS=0`: nada disso; `.env` sem `DOCKER_HOST`; o gancho pula a parte do Docker.

### 4.4 Diagnóstico, limites e limpeza
- **Diagnóstico e painel de decisão** (`--so-checar`, somente leitura: não cria, não grava, não reinicia nada, nunca imprime o token). Mostra, nesta ordem, o que a pessoa precisa para decidir se instala: **Sistema** (distribuição, arquitetura, kernel, systemd e `apt-get` presentes, carga); **Docker rootless** (ligado ou não; Docker instalado; repositório apt do Docker configurado; `max_user_namespaces`; `newuidmap`); **Instâncias nesta VPS** (nome, URL, `MemoryMax`, `CPUQuota` e estado do serviço de cada uma, a atual marcada, e o total de memória reservado); **Esta instância** (instalação nova ou já instalada, usuário, serviço, registro `.runner`, URL configurada); **Avisos** (URL configurada diferente da informada; restrição de user namespaces do AppArmor com rootless ligado); e por fim **Recursos e veredito** (memória total, disponível, swap, reserva, CPUs, disco livre no ponto de montagem de `/opt/runner-vps` ou `/`; `VEREDITO: cabe (…)` ou `não cabe: <motivos>`). Quando falta memória, antes do veredito vem uma linha com os números: quanto sobraria para o runner, o mínimo e **quantos MB disponíveis seriam necessários** com a reserva atual (e quantos faltam). Motivos de "não cabe": memória, cpu, disco, **systemd ausente**, **`apt-get` ausente** e **user namespaces desligados com `DOCKER_ROOTLESS=1`**. Os três últimos só valem quando o problema é detectado de forma positiva; dado que não existe no sistema aparece como "desconhecido" e não bloqueia. O mesmo veredito vale para a instalação, que recusa quando não cabe. O `registrar.sh` mostra esse painel inteiro ao assistente **antes** da confirmação, seja qual for a forma de conexão (Host salvo ou IP).
- **Limites**: `MEMORY_MAX_MB = MemAvailable − RESERVA_MB − (soma das outras instâncias)`, arredondado para baixo em múltiplos de 256; `CPU_QUOTA = max(100, (nproc − 1) × 100)`%. Padrões: `RESERVA_MB=1024`, `MEM_MIN_MB=2048`, `DISCO_MIN_GB=10` **(minha decisão)**. O dono pode fixar `MEMORY_MAX_MB` e `CPU_QUOTA` à mão; o instalador ainda recusa se ficarem abaixo dos mínimos.
- **Veredito**: `VEREDITO: cabe (MemoryMax=<n>M CPUQuota=<n>%)` e saída 0, ou `VEREDITO: não cabe: <motivo>` e saída 1 **sem criar nada**, mesmo com `RUNNER_TOKEN` definido.
- Gravação em `/etc/systemd/system/user-<uid>.slice.d/runner-vps.conf`: `MemoryMax`, `MemorySwapMax=0`, `CPUQuota`, `TasksMax=4096`. O runner, o Docker rootless e todos os contêineres do job contam juntos.
- **Gancho** `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` = `$HOME/bin/gancho-fim.sh`: se houver Docker, `docker compose ls -q` → `down -v --remove-orphans` em cada projeto (o daemon é só do CI, então todo projeto ali é do job), depois `docker system prune -f --filter until=24h`; grava uma linha em `$HOME/runner-vps.log` com data, `GITHUB_JOB`, `GITHUB_RUN_ID`, duração e disco livre; **sai sempre com 0**. Caches que ficam de propósito, por acelerarem o job seguinte: `~/.cache`, `~/.npm`, `_work/_tool` e camadas de imagem com menos de 24 h.
- **Extras do consumidor**, todos opcionais e idempotentes: `HOSTS_EXTRAS` (uma linha acrescentada a `/etc/hosts`, marcada `# runner-vps <nome>`); `PACOTES_EXTRAS` (apt, separados por espaço); `EXTRAS_SH` (caminho de um script na VPS, ou URL `https://` com `EXTRAS_SHA256`, executado como root depois da instalação; para dependências como bibliotecas de um navegador); `ENV_EXTRAS` (4.2).

### 4.5 O que muda no repositório que usa o runner
- Em cada job do workflow: `runs-on: ${{ vars.CI_RUNS_ON && fromJSON(vars.CI_RUNS_ON) || 'ubuntu-latest' }}`. Variável de repositório `CI_RUNS_ON` com JSON: `["self-hosted","linux","<rótulo>"]` para a VPS, `"ubuntu-latest"` (com aspas) para voltar. Sem a variável, nada muda. Esse é o botão de volta: sem PR, sem aprovação **(minha decisão)**.
- Passos que só existem no runner do GitHub (`sudo`, caminhos como `/usr/bin/google-chrome`) ganham `if: runner.environment == 'github-hosted'`; o equivalente na VPS vem de `HOSTS_EXTRAS`, `PACOTES_EXTRAS`, `EXTRAS_SH` ou `ENV_EXTRAS`, ou de um passo com `if: runner.environment == 'self-hosted'`.
- `actions/checkout`, `setup-*`, `cache`, `upload-artifact` e `services:` funcionam sem mudança (o `services:` exige Docker: `DOCKER_ROOTLESS=1`).
- Workflows com segredos de valor (deploys, chaves SSH) **ficam nos runners do GitHub**, a não ser que o dono aceite que esses segredos passem pela VPS.

### 4.6 Operação
- **`registrar.sh`** (na máquina de quem administra; já implementado e testado): gera o token pela API do GitHub com o `gh` (`POST <repos/<dono>/<repo> | orgs/<org>>/actions/runners/registration-token`, ou `remove-token` no `--remover`), monta as variáveis como linhas `export` e as envia **pelo stdin do SSH, na frente do `instalar.sh`**. Assim o token não passa pela linha de comando (`ps`), pelo histórico do shell nem por arquivo. Subcomandos `--so-checar`, `--status`, `--sem-token`, `--remover`, `--mostrar` (imprime o que iria, com o token redigido, sem conectar). O `instalar.sh` **não depende** dele: continua aceitando as variáveis de qualquer origem, porque lê o ambiente **(minha decisão)**. Quem não tem `gh` pode gerar o token na interface e enviar à mão, pelo mesmo stdin.
- **Assistente interativo** (`registrar.sh --interativo`, ou `registrar.sh` sem argumentos num terminal): pergunta e valida, uma coisa por vez, e só então chama o próprio `registrar.sh` com os argumentos montados (um caminho só, sem lógica duplicada). Ordem: (0) `gh auth status`, antes de qualquer pergunta (falha rápido, sem tocar na VPS); (1) conexão: se o `~/.ssh/config` tem `Host` concretos (sem curingas `*`, `?`, `!`; só o arquivo principal, `Include` não é seguido), a **primeira pergunta** é como conectar: **1) um Host salvo** (padrão) ou **2) IP ou nome do servidor**. Em (1) o assistente lista os Hosts numerados, cada um com `usuário@hostname:porta` (via `ssh -G`, que não conecta), e a escolha é pelo número; usuário, porta e chave vêm do config e não são perguntados. Em (2), ou quando não há Hosts concretos (a pergunta nem aparece), pergunta **só o IP ou nome do host**, depois a **porta** (padrão 22), **verifica se algo responde como SSH** nela (banner `SSH-`, sem autenticar), e só então o **usuário** (padrão `root`) e a chave. Um nome digitado em (2) que o `ssh -G` resolve para outro hostname continua sendo tratado como Host do config (cobre os `Include`). Nos dois casos, por fim, teste de conexão real (BatchMode). `--vps` também aceita um alias do `~/.ssh/config` (sem `@`); **(1b) painel do servidor, logo depois de conectar e antes de qualquer pergunta sobre o repositório**: `--so-checar` sem nome nem URL (sistema, Docker, instâncias e recursos). Se o veredito for "não cabe", o assistente para ali, sem perguntar repositório, nome nem opções; (2) repositório (`<dono>/<repo>`) ou organização, com checagem de administrador; para `--repo`, consulta a visibilidade (`gh api repos/<dono>/<repo> --jq .private`): **público** gera um aviso de risco (PRs de fork rodando no servidor; o GitHub recomenda runner self-hosted só com repositórios privados) e a pergunta "Continuar mesmo assim?" (padrão não; recusar sai com 1, antes de checar nome, gerar token ou instalar); privado segue calado; falha ou resposta ilegível só avisa e segue; organização não é consultada **(minha decisão: a visibilidade vale por repositório, e o grupo padrão de runners da organização não atende repositórios públicos)**; (3) nome da instância (sugestão derivada do alvo), avisando se já existe `/etc/runner-vps/<nome>.conf` na VPS; (4) "ajustar opções avançadas?" (padrão não): `MEMORY_MAX_MB`, `CPU_QUOTA`, rótulos, Docker rootless; (5) o painel desta instância (`--so-checar` com nome, URL do alvo e opções avançadas, para detectar divergência e dar o veredito final; mostra só da seção da instância em diante, sem repetir o servidor; sem as linhas `==>` de andamento, via `--quieto`) e, se o veredito for "não cabe", para sem gerar token. Se o **motivo incluir memória**, o assistente explica as saídas (liberar memória ou usar uma VPS maior; reduzir `RESERVA_MB` e/ou `MEM_MIN_MB`, com menos folga para o resto da VPS; manter os jobs pesados nos runners do GitHub) e oferece **ajustar `RESERVA_MB` e `MEM_MIN_MB` e reavaliar o painel**, repetindo até caber ou a pessoa desistir (padrão: não ajustar); os valores escolhidos aparecem no resumo e vão para a instalação. Para outros motivos (disco, systemd…), não há o que ajustar e ele só para; (6) resumo e confirmação (padrão não); (7) instala, mostra `--status` e imprime o comando equivalente sem o assistente. Respostas inválidas repetem a pergunta; fim da entrada (EOF) aborta sem instalar. Argumentos já passados pulam as perguntas deles. **Não grava nada em disco** (nem perfil, nem histórico) e **nunca pergunta o token**, que continua sendo gerado pelo `gh` só depois da confirmação. Só serve para instalar: com `--status`, `--so-checar`, `--remover` ou `--sem-token` o `--interativo` é recusado (saída 2).
- Instalar / atualizar: `./registrar.sh --vps root@<vps>[:porta] --repo <dono>/<repo> --nome <nome> [--chave …]`. Sem `RUNNER_TOKEN` (`--sem-token`), o registro é pulado (útil para só atualizar limites ou extras). Segunda execução sem mudanças: nenhum arquivo alterado, nenhum serviço reiniciado.
- **Contrato do `instalar.sh` com o stdin**: ele é lido por `bash -s -- [subcomando]`, então as linhas `export` que o `registrar.sh` coloca antes já estão no ambiente quando o script começa; o script não lê o stdin.
- `instalar.sh --so-checar`: painel e veredito. `RUNNER_NOME` é opcional **só aqui**: sem ele o painel cobre apenas o servidor (sem a seção da instância); com um nome inválido continua recusando (saída 2). Os demais modos exigem `RUNNER_NOME`.
- `instalar.sh --status`: usuário, serviços (`runner-vps`, `docker`), limites, última linha do log, estado do runner segundo `.runner`/`.credentials` (existência, não conteúdo).
- `instalar.sh --remover` (precisa de `RUNNER_NOME` e `RUNNER_TOKEN`): `config.sh remove`, para e desabilita os serviços, remove o rootless (`dockerd-rootless-setuptool.sh uninstall` e os dados), apaga `$HOME`, a linha de `/etc/hosts`, o `.slice.d` e o `.conf`; apaga o usuário se não houver arquivo dele fora do HOME. Linhas de `/etc/subuid` ficam **(minha decisão)**: são inofensivas e evitam colisão se a instância voltar.
- Se o runner cai, os jobs ficam em *Waiting for a runner* e o GitHub os cancela em 24 h: troque `CI_RUNS_ON` ou `systemctl --user -M runner-<nome>@ restart runner-vps`. Causa comum: disco cheio (`docker system prune -af` como o usuário).

## 5. Ordem sugerida (para o plano)
1. Harness de testes em bash (VPS falsa em diretório temporário, comandos falsos) e CI do projeto (shellcheck + testes).
2. `instalar.sh`: argumentos, configuração persistida, diagnóstico e veredito.
3. `instalar.sh`: instalação completa, idempotência, `--status`, `--remover`.
4. `gancho-fim.sh`.
5. README final com o passo a passo e a convenção do consumidor.

## 6. O que fica para quem constrói
- Versão do runner e sha256 (da release oficial no dia), e a lógica de escolher uma faixa livre em `/etc/subuid`.
- Como detectar o ponto de montagem de `/opt/runner-vps` (`df --output=target`).
- Formato exato da linha do log e do `--status`.
- Se o harness de testes usa `bats` (dependência) ou um arquivo `testes/harness.sh` próprio **(sugestão: próprio, sem dependência)**.
- Como passar `RUNNER_TOKEN` com segurança pelo `ssh 'bash -s'` (a variável precisa ser definida no comando remoto, não no local); o README traz a forma final e avisa sobre o histórico do shell.

## 7. Decisões
| # | Decisão | Quem decidiu | Data |
| --- | --- | --- | --- |
| 1 | Projeto agnóstico, em repositório próprio e público, sem nenhum dado do repositório consumidor nem da VPS | dono | 13/11/2026 |
| 2 | Docker rootless opcional, ligado por padrão | dono | 13/11/2026 |
| 3 | Documentação: README + `docs/design.md` + `docs/plano.md`; licença MIT | dono | 13/11/2026 |
| 4 | Usuário por instância, sem sudo e sem grupo `docker`; nunca o socket de root | **(minha decisão)** | 13/11/2026 |
| 5 | Runner persistente com gancho de limpeza; serviços `systemd --user`; limites na fatia do usuário | **(minha decisão)** | 13/11/2026 |
| 6 | `runs-on` por variável `CI_RUNS_ON` no consumidor; sem variável = `ubuntu-latest` | **(minha decisão)** | 13/11/2026 |
| 7 | Mínimos padrão: 2 GB, 1 CPU, 10 GB de disco; reserva padrão 1 GB; sobrescrevíveis | **(minha decisão)** | 13/11/2026 |
| 8 | Só `apt` (Ubuntu/Debian) na primeira versão | **(minha decisão)** | 13/11/2026 |
| 9 | Configuração persistida em `/etc/runner-vps/<nome>.conf`, sem token | **(minha decisão)** | 13/11/2026 |

## 8. Pendências
- [ ] **Self-hosted é cobrado no plano Free?** O GitHub anunciou e depois reviu uma cobrança por minuto de runners self-hosted em 2026. Conferir a página de preços atual antes de aprovar. **Quem responde: dono.**
- [ ] **A conta bloqueada por cobrança ainda despacha jobs para self-hosted?** Só se descobre no primeiro PR de teste. Se não despachar, a conta precisa ser regularizada primeiro. **Quem responde: dono, na instalação.**

Sem pendência aberta, a spec pode ser aprovada.

## 9. Grilling concluído
Grilling concluído: **não**

Falta ao dono confirmar as duas pendências. As escolhas dele já feitas (agnóstico, público, rootless opcional, formato dos documentos, MIT) estão na tabela de decisões.
