# runner-vps

Instala um runner self-hosted do GitHub Actions numa VPS Linux, de forma segura e repetível, para **qualquer** repositório ou organização. Serve para quem esgota os minutos do plano gratuito do GitHub Actions e já tem uma VPS.

O runner roda num usuário próprio, **sem sudo e sem o grupo `docker`**, com um Docker **rootless** separado (opcional, ligado por padrão), dentro de uma fatia do systemd com limites de memória e CPU. Um PR malicioso ou errado não consegue chegar aos contêineres, aos arquivos nem aos segredos do resto da VPS.

**Situação:** `registrar.sh`, `instalar.sh` e `gancho-fim.sh` estão implementados e testados contra uma VPS falsa (`testes/rodar.sh`, mais `shellcheck` na CI). **Ainda não há uma instalação real validada** (a tag `v0.1.0` espera por ela): comece sempre por `--so-checar`. Veja [Pendências](#pendências). Agentes de IA: leia [CLAUDE.md](CLAUDE.md) ou [AGENTS.md](AGENTS.md); a spec está em [docs/design.md](docs/design.md) e o plano em [docs/plano.md](docs/plano.md).

## Pré-requisitos

- **Na sua máquina:** `bash`, `ssh` e o [`gh`](https://cli.github.com) autenticado como **administrador** do repositório (ou da organização). O `gh` só serve para gerar o token de registro.
- **Na VPS:** Debian ou Ubuntu (usa `apt`), `systemd` e acesso SSH como **root**. Se não houver Docker, o instalador configura o repositório apt oficial dele (veja abaixo).
- Memória, CPU e disco folgados: o instalador mede e recusa com `VEREDITO: não cabe` (mínimos padrão: 2048 MB para o runner, 1024 MB de reserva para o resto da VPS, 10 GB de disco).

## Instalar com um comando

```bash
# 1. só o painel de decisão: sistema, recursos, instâncias, estado e veredito (não cria nada, não precisa de token)
#    (sem --nome, mostra só o servidor; com --nome, também a situação dessa instância)
./registrar.sh --vps root@<vps>:<porta> --nome <nome> --so-checar --chave ~/.ssh/<chave>

# 2. instalar
./registrar.sh --vps root@<vps>:<porta> --repo <dono>/<repo> --nome <nome> --chave ~/.ssh/<chave>
```

O `registrar.sh` gera o token de registro pela API (`gh api … registration-token`), monta as variáveis e envia o `instalar.sh` pelo SSH. O token vai pelo fluxo de entrada do SSH, junto com o script: **não passa pela linha de comando, pelo histórico nem por arquivo**; dentro da VPS, chega ao `config.sh` do runner por variável de ambiente, só durante a chamada, e nunca é gravado.

### Assistente interativo

Se preferir ser guiado, rode sem argumentos num terminal (ou use `--interativo`):

```bash
./registrar.sh
```

Ele pergunta, valida e só instala depois da sua confirmação:

1. confere se o `gh` está autenticado (antes de qualquer pergunta);
2. **como conectar**: se o seu `~/.ssh/config` tiver `Host` salvos, a primeira pergunta é *"usar um Host salvo (1) ou informar o IP (2)"*. Escolhendo **1**, ele lista os Hosts numerados, cada um com `usuário@hostname:porta`, e você escolhe pelo número; usuário, porta e chave vêm do arquivo (inclusive `IdentityFile` e `ProxyJump`). Escolhendo **2** (ou se não houver Hosts salvos, caso em que a pergunta nem aparece), ele pede **só o IP ou nome do host**, depois a **porta** (Enter = 22), **verifica se algo responde como SSH** nela e só então pergunta o **usuário** (Enter = `root`) e a chave. Nos dois casos termina com um teste de conexão de verdade. Se quiser instalar **na própria máquina** em que está, digite `local` no lugar do servidor (veja "Esta máquina e vários repositórios"). Só o arquivo `~/.ssh/config` é lido: `Include` não é seguido (mas um alias vindo de um `Include` ainda funciona se você digitar o nome em **2**);
3. **se a VPS já tiver instâncias** (e você não passou `--nome`, `--repo` nem `--org`), um **menu**: *instalar uma instância nova* (padrão, segue os passos abaixo), *ver o estado*, *ver ou alterar a configuração* ou *remover* uma instância (escolhida pelo número, ou direto se houver só uma). Alterar a configuração mostra o que está gravado e pergunta a **memória máxima**, a **cota de CPU**, a **janela de horário** e a **validade** (Enter mantém; `-` remove janela ou validade); só o que mudou é reaplicado, **sem token e sem registrar de novo**. Remover confirma (padrão: não), confere que você é administrador e usa o repositório ou a organização gravados na configuração;
4. o **painel do servidor** (veja abaixo), **logo depois de conectar e antes de perguntar o repositório**: sistema, Docker, instâncias e recursos. Se o veredito for "não cabe", para aí, sem perguntar mais nada nem gerar token. Se o painel **falhar** antes de dar veredito (por exemplo, `ERRO: rode como root.` porque o usuário do SSH não é root), ele diz isso com outras palavras, para não parecer que a VPS é pequena demais. Se o motivo for **memória**, ele explica as saídas e oferece **ajustar a reserva e o mínimo de memória e reavaliar o painel** (veja "Quando não cabe por memória");
5. repositório (`<dono>/<repo>`) ou organização, conferindo que você é **administrador**. Se o repositório for **público**, ele avisa do risco (qualquer pessoa pode abrir um pull request de um fork, e os workflows rodariam no seu servidor; o GitHub recomenda runner self-hosted só com repositórios privados) e pergunta *"Continuar mesmo assim?"* (padrão: não). Se não conseguir consultar a visibilidade, avisa e segue; para organizações não consulta;
6. nome da instância (sugerido a partir do alvo), avisando se **já existe** na VPS;
7. opções avançadas, só se você quiser: memória máxima, cota de CPU, rótulos, **janela de horário**, **validade** e Docker rootless;
8. o **painel desta instância**, que completa o do servidor com a situação da instância, os avisos que dependem do repositório e o veredito final já com as suas opções (mostra só a parte nova, sem repetir o servidor). O ajuste de memória também é oferecido aqui, se for ele o problema;
9. um resumo e a confirmação (padrão: não). Só então instala, mostra o `--status` e imprime o **comando equivalente sem o assistente**, para repetir noutra VPS.

Respostas inválidas repetem a pergunta; Ctrl-C ou fim da entrada cancelam sem instalar. O assistente **não grava nada em disco** (nem perfil, nem histórico) e **nunca pergunta o token**: ele é gerado pelo `gh` só no passo de instalação. Argumentos que você já passar (`--vps`, `--repo`, `--nome`…) pulam as perguntas deles. O `--vps` também aceita o nome de um `Host` do `~/.ssh/config` (`./registrar.sh --vps meu-servidor --repo <dono>/<repo> --nome <nome>`), sem `usuário@` nem `:porta`. Como o `ssh` roda com `BatchMode`, uma chave com senha precisa estar no `ssh-agent`.

### Painel de decisão (`--so-checar`)

`./registrar.sh --vps … --nome <nome> --so-checar` (e o assistente, antes de pedir a confirmação) mostra tudo o que ajuda a decidir se vale instalar. **É somente leitura**: não cria, não grava, não reinicia nada e nunca imprime o token.

| Seção | O que mostra |
| --- | --- |
| **Sistema** | distribuição, arquitetura, kernel, se há `systemd` e `apt-get`, carga (1, 5 e 15 min) |
| **Docker rootless** | se está ligado, se o Docker já está instalado, se o repositório apt do Docker já está configurado, `max_user_namespaces`, `newuidmap` |
| **Instâncias nesta VPS** | cada uma com URL, `MemoryMax`, `CPUQuota` e estado do serviço (a atual marcada), mais a memória reservada no total |
| **Esta instância** | instalação nova ou já instalada (reaplicar é idempotente), usuário, serviço, registro `.runner`, URL configurada |
| **Avisos** | URL configurada diferente da informada; AppArmor restringindo user namespaces com rootless ligado |
| **Recursos e veredito** | swap, memória (total, disponível, reserva, outras instâncias), CPUs, disco livre e, por último, `VEREDITO: cabe (…)` ou `não cabe: <motivos>` |

Motivos de "não cabe": memória, CPU, disco, **`systemd` ausente**, **`apt-get` ausente** e **user namespaces desligados** (com `DOCKER_ROOTLESS=1`). Os três últimos só valem quando o problema é detectado de verdade: se o sistema não informa o dado (por exemplo, não existe `max_user_namespaces`), o painel mostra "desconhecido" e não bloqueia. A instalação usa o mesmo veredito e recusa quando não cabe.

#### Quando não cabe por memória

Quando falta memória, o painel mostra a conta antes do veredito, por exemplo: *"sobrariam 768 MB para o runner (mínimo 2048 MB). Com a reserva de 1024 MB e 0 MB de outras instâncias, seriam necessários 3072 MB disponíveis (faltam 1233 MB)"*. O limite do runner é a memória **disponível** menos a reserva (`RESERVA_MB`, padrão 1024) menos o que as outras instâncias reservaram, e precisa ser pelo menos `MEM_MIN_MB` (padrão 2048).

As saídas são: liberar memória ou usar uma VPS maior; **reduzir `RESERVA_MB` e/ou `MEM_MIN_MB`**; ou manter os workflows pesados nos runners do GitHub. O assistente oferece a segunda na hora: pergunta os dois valores (os últimos escolhidos viram o padrão), reavalia o painel e repete até caber ou você desistir. Os ajustes aparecem no resumo e vão para a instalação. Pela linha de comando: `--var RESERVA_MB=256 --var MEM_MIN_MB=1536`.

Atenção: reduzir deixa menos folga para os outros serviços da VPS crescerem. O limite do runner continua valendo, então um job que estourar a memória derruba só o runner, desde que sobre folga no resto da VPS. Abaixo de 1024 MB de mínimo, jobs com Docker podem ser mortos por falta de memória.

Outras formas:

```bash
./registrar.sh --vps root@<vps> --nome <nome> --status         # estado da instância
./registrar.sh --vps root@<vps> --listar                       # nomes das instâncias da VPS
./registrar.sh --vps root@<vps> --nome <nome> --config         # configuração gravada da instância (CHAVE=valor)
./registrar.sh --vps root@<vps> --nome <nome> --sem-token      # atualizar limites/extras sem registrar de novo
./registrar.sh --vps root@<vps> --repo <dono>/<repo> --nome <nome> --remover
./registrar.sh … --mostrar                                     # imprime o que seria enviado (token redigido) e não conecta
```

Opções: `--interativo` (assistente); `--quieto` (sem as linhas `==>` de andamento); `--org <org>` no lugar de `--repo`; `--rotulos a,b`; `--nome-github`; `--sem-docker`; `--var CHAVE=valor` (repetível) para qualquer variável da tabela abaixo. `./registrar.sh --help` lista tudo.

Sem o `registrar.sh`, o equivalente à mão é enviar as variáveis e o script pelo stdin do SSH (o `printf` é um comando interno do shell, então o token não aparece em `ps`; evite colar o token literal no terminal, por causa do histórico):

```bash
{ printf 'export RUNNER_URL=%q RUNNER_NOME=%q RUNNER_TOKEN=%q\n' https://github.com/<dono>/<repo> <nome> "$(gh api -X POST repos/<dono>/<repo>/actions/runners/registration-token --jq .token)"; cat instalar.sh; } | ssh root@<vps> 'bash -s'
```

Para um subcomando, use `bash -s -- --so-checar` (ou `--listar`, `--config`, `--status`, `--remover`).

## O que o `instalar.sh` faz

1. Diagnostica a VPS e para com `VEREDITO: não cabe` se faltar memória, CPU ou disco, **sem criar nada**.
2. Cria o usuário `runner-<nome>` (sem sudo, sem grupo `docker`, sem chave SSH) com `linger` ligado.
3. Instala o Docker rootless desse usuário (se `DOCKER_ROOTLESS=1`, o padrão). Numa VPS sem Docker, configura antes o repositório apt oficial (Debian ou Ubuntu), com a **chave GPG fixada pelo fingerprint** `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`: recusa um arquivo com outro fingerprint ou com mais de uma chave. Se você já tem o repositório do Docker configurado, ele não mexe. Se `dockerd-rootless-setuptool.sh check` falhar, **para com o motivo**; não existe alternativa com o socket de root.
4. Baixa o runner do GitHub com versão e sha256 fixos e o registra (se houver `RUNNER_TOKEN`).
5. Grava a unidade `systemd --user`, o `.env` do runner, os limites da fatia do usuário (`MemoryMax`, `MemorySwapMax=0`, `CPUQuota`, `TasksMax=4096`), o gancho de fim de job e a configuração em `/etc/runner-vps/<nome>.conf` (`chmod 600`, sem token).
6. Liga tudo e imprime o estado.

Rodar de novo não altera nenhum arquivo nem reinicia nada se nada mudou. Uma VPS pode ter **várias instâncias** (um `RUNNER_NOME` por repositório), cada uma com usuário, Docker, limites e log próprios; cada nova desconta a memória das anteriores.

O **gancho de fim de job** (`gancho-fim.sh`) derruba os projetos `docker compose` que o job deixou, faz o prune de camadas com mais de 24 h e grava uma linha em `$HOME/runner-vps.log` (data, job, run, estado do Docker, disco livre). Sai sempre com 0.

## Variáveis

Valem em `--var CHAVE=valor` do `registrar.sh` ou no ambiente do `instalar.sh`. Na primeira execução vêm das variáveis; nas seguintes o `.conf` é a fonte e as variáveis presentes o sobrescrevem.

| Variável | Padrão | Para quê |
|---|---|---|
| `RUNNER_NOME` | (obrigatória) | Nome da instância, `[a-z0-9-]+`. Define usuário `runner-<nome>`, HOME `/opt/runner-vps/<nome>` e o `.conf`. |
| `RUNNER_URL` | (obrigatória no 1º instalar) | `https://github.com/<dono>/<repo>` ou `https://github.com/<org>`. O `registrar.sh` monta. |
| `RUNNER_TOKEN` | (sem) | Token de registro (ou de remoção, no `--remover`). Uso único; nunca gravado. Sem ele, o registro é pulado. |
| `RUNNER_NOME_GITHUB` | `RUNNER_NOME` | Nome do runner no GitHub. |
| `RUNNER_ROTULOS` | `RUNNER_NOME` | Rótulos; o GitHub acrescenta `self-hosted`, `Linux` e a arquitetura. |
| `DOCKER_APT_FINGERPRINT` | o fixado no script | Fingerprint esperado da chave do repositório do Docker (só para casos especiais; não é gravado no `.conf`). |
| `RUNNER_VERSAO`, `RUNNER_SHA256` | `2.338.2` e o sha fixo da arquitetura | Outra versão do runner; `RUNNER_VERSAO` exige `RUNNER_SHA256` da mesma release. O runner se atualiza sozinho depois. |
| `DOCKER_ROOTLESS` | `1` | `0` desliga o Docker (sem `services:` nos jobs). |
| `RESERVA_MB` | `1024` | Memória que fica para o resto da VPS. |
| `MEM_MIN_MB` | `2048` | Abaixo disso, "não cabe". |
| `DISCO_MIN_GB` | `10` | Abaixo disso, "não cabe". |
| `MEMORY_MAX_MB` | calculado | `MemAvailable − RESERVA_MB − outras instâncias`, em múltiplos de 256. Gravado no `.conf` e daí em diante vale como fixado; apague a linha para recalcular. |
| `CPU_QUOTA` | `max(100, (nproc−1)×100)` | Em %. Também gravado no `.conf`. |
| `HOSTS_EXTRAS` | (vazio) | Uma linha para o `/etc/hosts`, marcada `# runner-vps <nome>`. |
| `PACOTES_EXTRAS` | (vazio) | Pacotes apt extras, separados por espaço. |
| `EXTRAS_SH` | (vazio) | Script executado como root no fim: caminho absoluto na VPS, ou URL `https://` com `EXTRAS_SHA256`. Deve ser idempotente. |
| `EXTRAS_SHA256` | (vazio) | sha256 do `EXTRAS_SH` por URL. |
| `ENV_EXTRAS` | (vazio) | `CHAVE=valor` separados por `;`, repassados aos jobs pelo `.env` do runner. |
| `JANELA` | (vazio = sempre ligado) | Horário em que o runner fica ligado, `HH:MM-HH:MM` (24 h, **horário da VPS**; pode atravessar a meia-noite, ex.: `22:00-06:00`; o fim é exclusivo). Fora dele o runner é desligado, **esperando o job em andamento terminar**. Veja "Janela de horário e validade". |
| `VALIDADE` | (vazio = sem validade) | Data `AAAA-MM-DD`. No fim desse dia (23:59, horário da VPS) o runner se desliga e se desabilita sozinho. Veja "Janela de horário e validade". |
| `JANELA_ESPERA_MIN` | `120` | Quanto esperar (minutos) um job terminar antes de desligar o runner na hora do fim da janela ou da validade; passado isso, o runner é desligado mesmo assim e o job é cancelado. |

## No repositório que vai usar o runner

Troque, em cada job do workflow:

```yaml
runs-on: ${{ vars.CI_RUNS_ON && fromJSON(vars.CI_RUNS_ON) || 'ubuntu-latest' }}
```

e crie a variável de repositório `CI_RUNS_ON` com `["self-hosted","linux","<rótulo>"]`. Para voltar aos runners do GitHub, grave `"ubuntu-latest"` (com aspas) ou apague a variável: é o botão de volta, sem PR. Sem a variável, nada muda.

Passos que só existem no runner do GitHub (`sudo`, caminhos como `/usr/bin/google-chrome`) ganham:

```yaml
- name: Instalar dependência do runner do GitHub
  if: runner.environment == 'github-hosted'
  run: sudo apt-get install -y <pacote>
```

e o equivalente na VPS vem de `HOSTS_EXTRAS`, `PACOTES_EXTRAS`, `EXTRAS_SH` ou `ENV_EXTRAS` (ou de um passo com `if: runner.environment == 'self-hosted'`). `actions/checkout`, `setup-*`, `cache`, `upload-artifact` e `services:` funcionam sem mudança (`services:` exige `DOCKER_ROOTLESS=1`). Detalhes em [docs/design.md](docs/design.md#45-o-que-muda-no-repositório-que-usa-o-runner).

## Janela de horário e validade

```bash
./registrar.sh … --var JANELA=22:00-06:00 --var VALIDADE=2026-12-31
```

- **Janela:** o runner só fica ligado no horário dado (o da VPS: confira com `date` lá). Dois disparos de um timer do systemd (do sistema, não do usuário do runner) ligam e desligam o serviço, e um terceiro, 1 minuto depois da inicialização, acerta o estado se a VPS reiniciar. Com janela, o serviço do runner **não sobe sozinho na inicialização**: quem o liga é o timer. Fora da janela, os jobs ficam na fila do GitHub (que os cancela depois de 24 h) até a janela abrir. Para desligar, o script espera o job em andamento terminar (até `JANELA_ESPERA_MIN`, padrão 120 minutos) e só então para o serviço.
- **Validade:** no fim do dia dado o runner é parado e **desabilitado** e uma marca em `/etc/runner-vps/<nome>.expirada` registra a expiração. O registro no GitHub **continua lá** (o runner só fica offline): para tirá-lo, use `--remover`. Reaplicar com a mesma `VALIDADE` vencida é recusado; para reativar, informe outra `VALIDADE` (ou `VALIDADE=` para ficar sem). Uma `VALIDADE` já passada é recusada na instalação.
- O script que os timers chamam fica em `/etc/runner-vps/ciclo-<nome>.sh`, **de root**, e não dentro do HOME do runner (que o próprio usuário pode editar). `--status` mostra a janela, a validade e se a instância já expirou; `--config` mostra o que está gravado.
- Para remover as duas: `--var JANELA= --var VALIDADE=`. Timers, script e marca somem e o runner volta a ficar sempre ligado.
- O assistente pergunta as duas nas opções avançadas e, no menu de configuração, mostra os valores atuais (`-` remove).

## Esta máquina e vários repositórios

```bash
# instalar na própria máquina (Linux), sem SSH
./registrar.sh --local --repo <dono>/<repo> --nome <nome>

# uma instância para cada repositório, numa passada (na VPS ou com --local)
./registrar.sh --vps root@<vps> --repos <dono>/<a>,<dono>/<b>
```

- **`--local`** roda o instalador nesta máquina em vez de enviá-lo por SSH (`--vps` e `--chave` não valem junto). Exige Linux e **root ou `sudo`**; o `sudo` é só para o instalador, que cria usuários e unidades do sistema. O runner em si continua sem `sudo`, sem o grupo `docker` e sem o socket do Docker de root. Vale para todos os modos (`--so-checar`, `--status`, `--config`, `--listar`, `--remover`, `--sem-token`). Instalar no seu próprio computador de trabalho coloca o runner (e o que o workflow executar) ao lado dos seus arquivos: prefira uma máquina dedicada.
- **`--repos a/x,b/y`** instala **uma instância por repositório**. O nome de cada uma vem do nome do repositório (minúsculas, o que não for letra ou número vira `-`: `Beta_X.y` vira `beta-x-y`); nomes repetidos são recusados. O painel do servidor roda **uma vez, antes de qualquer token**; a memória que ele diz que cabe é **dividida em partes iguais** (arredondada para baixo, em múltiplos de 256 MB) e cada instância recebe a sua fatia em `MEMORY_MAX_MB`. Se a fatia ficar abaixo de `MEM_MIN_MB` (2048 MB por padrão), nada é instalado e a mensagem diz o que fazer: menos repositórios, uma VPS maior ou `--var MEM_MIN_MB=1024`. Com `--var MEMORY_MAX_MB=<MB>` você define a fatia à mão e o cálculo é pulado. A cota de CPU não é dividida: cada instância usa a que o diagnóstico calcular. Cada instalação gera o seu próprio token; a primeira que falhar **interrompe o lote** e a mensagem lista o que foi instalado e o que não foi tentado (reaplicar é idempotente). `--repos` só instala: não combina com `--repo`, `--org`, `--nome`, `--nome-github`, `--status`, `--so-checar`, `--remover` nem `--mostrar`.
- **Um runner para todos os repositórios de uma conta:** o GitHub só oferece runner de **organização** (`--org <org>`, já suportado). Conta pessoal não tem runner compartilhado; `--repos` é o caminho, com uma instância por repositório.

## Perfil (`--perfil`) e runner nativo

Para não repetir as mesmas opções a cada comando, guarde-as num arquivo **fora do repositório** e use `--perfil`:

```bash
cp exemplos/perfil-nativo.perfil ~/.config/runner-vps/meu-servidor.perfil   # troque os marcadores <…>
./registrar.sh --perfil ~/.config/runner-vps/meu-servidor.perfil
./registrar.sh --perfil ~/.config/runner-vps/meu-servidor.perfil --status
```

- Uma `chave=valor` por linha; a chave é o nome da opção sem `--`: `vps`, `chave`, `local`, `repo`, `org`, `repos`, `nome`, `nome-github`, `rotulos`, `sem-docker` (as duas de uma flag só aceitam o valor `1`) e `var=CHAVE=valor` (repetível). Linhas em branco e comentários inteiros (`#`) são ignorados.
- O arquivo **não é executado nem expandido** (só o `~/` inicial de `chave` vira o seu HOME), **não aceita token** (o `registrar.sh` o gera pelo `gh`) e **perde para a linha de comando**: `--perfil x.perfil --nome outro` usa `outro`.
- **Runner nativo (sem Docker):** `sem-docker=1` (ou `DOCKER_ROOTLESS=0`). O runner roda no próprio sistema, como um usuário dedicado (`runner-<nome>`) sem `sudo` e sem o grupo `docker`, com os limites de memória e CPU da instância; não há daemon do Docker, então o consumo é só o do runner e dos jobs. Workflows que precisam de `docker` não funcionam nesse modo.

## Operação

- **Ver o estado:** `./registrar.sh --vps root@<vps> --nome <nome> --status` (usuário, serviços, limites, registro e a última linha do log).
- **Verificar a instalação:** `./registrar.sh --vps root@<vps> --nome <nome> --verificar` (só leitura, sem token). Uma lista de `ok:`, `aviso:` e `FALHA:`: o usuário existe e **não** tem sudo (nem os grupos `sudo`, `wheel`, `admin`, `docker`, nem entrada no sudoers); `.runner` e `run.sh` existem e o diretório do runner e seus arquivos são do usuário da instância; o serviço está ativo; o `Runner.Listener` roda como o usuário (e **não** como root); `ExecStart` e `WorkingDirectory` da unidade apontam para o runner da instância; o linger está ligado; o journal não tem erro de `CHDIR` nem de `node` não encontrado. Sai com 1 se houver alguma `FALHA` e então sugere os comandos de diagnóstico. Com **janela** ou **validade vencida**, serviço e processo parados viram só `aviso`. Não rode o `run.sh` à mão com o serviço ativo: seriam duas instâncias do mesmo runner.
- **Ver a configuração:** `./registrar.sh --vps root@<vps> --nome <nome> --config` (o que está gravado em `/etc/runner-vps/<nome>.conf`; nunca há token nele). `--listar` mostra os nomes das instâncias. O assistente reúne tudo isso no menu.
- **Administrar na VPS:** `sudo -u runner-<nome> …` e `systemctl --user -M runner-<nome>@ status runner-vps`.
- **Mudar limites ou extras:** `./registrar.sh … --sem-token --var MEMORY_MAX_MB=3072` (só reescreve o que mudou e faz `daemon-reload`; o diagnóstico roda de novo e recusa se o novo limite não couber). Mudar **rótulos** ou o **nome no GitHub** exige registrar de novo, ou seja, token (`./registrar.sh … --repo … --rotulos …`).
- **Se o runner cair:** os jobs ficam em *Waiting for a runner* e o GitHub os cancela em 24 h. Troque `CI_RUNS_ON` para voltar aos runners do GitHub enquanto resolve, ou reinicie: `systemctl --user -M runner-<nome>@ restart runner-vps`. Causa comum: **disco cheio**; limpe como o usuário do runner com `docker system prune -af`.
- **Remover:** `./registrar.sh … --repo <dono>/<repo> --nome <nome> --remover`. Apaga o HOME, o `.conf`, a fatia e a linha do `/etc/hosts`; o usuário só é apagado se não houver arquivo dele fora do HOME; as linhas de `/etc/subuid` ficam. Se o `config.sh remove` falhar (token de remoção expirado, por exemplo), nada é apagado.

## Limites conhecidos

- Em `pull_request`, o GitHub roda o workflow **da branch do PR**: quem tem escrita no repositório executa o que quiser no runner. A defesa é o runner não ter nada de valor e não alcançar nada de valor; não é isolamento perfeito. Não use em repositório público que aceite PR de desconhecidos sem aprovação.
- Workflows com segredos de valor (deploys, chaves SSH) **ficam nos runners do GitHub**, a não ser que você aceite que esses segredos passem pela VPS.
- Um runner executa um job por vez.
- Nunca dê ao runner o socket do Docker de root. Se o rootless não funcionar na sua VPS, use outra máquina.

## Pendências

- **Primeira instalação real:** `useradd`, `systemctl --user -M`, `loginctl` e o Docker rootless só foram exercitados por comandos falsos, e a configuração do repositório do Docker só com chaves falsas (o fingerprint fixado vem da documentação do Docker, mas o arquivo real não foi baixado nos testes). Rode `--so-checar` e acompanhe a primeira instalação.
- O log do gancho não registra a duração do job (exigiria um gancho de início de job).

## Testes

```bash
testes/rodar.sh                        # todos os testes (bash puro, sem rede, sem Docker, sem root)
shellcheck -S warning *.sh testes/*.sh
```

A CI do projeto (`.github/workflows/ci.yml`) roda os dois.

## Licença

MIT. Veja [LICENSE](LICENSE).
