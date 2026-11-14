# runner-vps

Instala um runner self-hosted do GitHub Actions numa VPS Linux, de forma segura e repetível, para **qualquer** repositório ou organização. Serve para quem esgota os minutos do plano gratuito do GitHub Actions e já tem uma VPS.

O runner roda num usuário próprio, **sem sudo e sem o grupo `docker`**, com um Docker **rootless** separado (opcional, ligado por padrão), dentro de uma fatia do systemd com limites de memória e CPU. Um PR malicioso ou errado não consegue chegar aos contêineres, aos arquivos nem aos segredos do resto da VPS.

**Situação:** `registrar.sh`, `instalar.sh` e `gancho-fim.sh` estão implementados e testados contra uma VPS falsa (`testes/rodar.sh`, mais `shellcheck` na CI). **Ainda não há uma instalação real validada** (a tag `v0.1.0` espera por ela): comece sempre por `--so-checar`. Veja [Pendências](#pendências). Agentes de IA: leia [CLAUDE.md](CLAUDE.md) ou [AGENTS.md](AGENTS.md); a spec está em [docs/design.md](docs/design.md) e o plano em [docs/plano.md](docs/plano.md).

## Pré-requisitos

- **Na sua máquina:** `bash`, `ssh` e o [`gh`](https://cli.github.com) autenticado como **administrador** do repositório (ou da organização). O `gh` só serve para gerar o token de registro.
- **Na VPS:** Debian ou Ubuntu (usa `apt`), `systemd`, acesso SSH como **root**, e, para o Docker rootless, o repositório apt oficial do Docker já configurado (veja [Pendências](#pendências)).
- Memória, CPU e disco folgados: o instalador mede e recusa com `VEREDITO: não cabe` (mínimos padrão: 2048 MB para o runner, 1024 MB de reserva para o resto da VPS, 10 GB de disco).

## Instalar com um comando

```bash
# 1. só o diagnóstico: cabe ou não cabe (não cria nada, não precisa de token)
./registrar.sh --vps root@<vps>:<porta> --nome <nome> --so-checar --chave ~/.ssh/<chave>

# 2. instalar
./registrar.sh --vps root@<vps>:<porta> --repo <dono>/<repo> --nome <nome> --chave ~/.ssh/<chave>
```

O `registrar.sh` gera o token de registro pela API (`gh api … registration-token`), monta as variáveis e envia o `instalar.sh` pelo SSH. O token vai pelo fluxo de entrada do SSH, junto com o script: **não passa pela linha de comando, pelo histórico nem por arquivo**; dentro da VPS, chega ao `config.sh` do runner por variável de ambiente, só durante a chamada, e nunca é gravado.

Outras formas:

```bash
./registrar.sh --vps root@<vps> --nome <nome> --status         # estado da instância
./registrar.sh --vps root@<vps> --nome <nome> --sem-token      # atualizar limites/extras sem registrar de novo
./registrar.sh --vps root@<vps> --repo <dono>/<repo> --nome <nome> --remover
./registrar.sh … --mostrar                                     # imprime o que seria enviado (token redigido) e não conecta
```

Opções: `--org <org>` no lugar de `--repo`; `--rotulos a,b`; `--nome-github`; `--sem-docker`; `--var CHAVE=valor` (repetível) para qualquer variável da tabela abaixo. `./registrar.sh --help` lista tudo.

Sem o `registrar.sh`, o equivalente à mão é enviar as variáveis e o script pelo stdin do SSH (o `printf` é um comando interno do shell, então o token não aparece em `ps`; evite colar o token literal no terminal, por causa do histórico):

```bash
{ printf 'export RUNNER_URL=%q RUNNER_NOME=%q RUNNER_TOKEN=%q\n' https://github.com/<dono>/<repo> <nome> "$(gh api -X POST repos/<dono>/<repo>/actions/runners/registration-token --jq .token)"; cat instalar.sh; } | ssh root@<vps> 'bash -s'
```

Para um subcomando, use `bash -s -- --so-checar` (ou `--status`, `--remover`).

## O que o `instalar.sh` faz

1. Diagnostica a VPS e para com `VEREDITO: não cabe` se faltar memória, CPU ou disco, **sem criar nada**.
2. Cria o usuário `runner-<nome>` (sem sudo, sem grupo `docker`, sem chave SSH) com `linger` ligado.
3. Instala o Docker rootless desse usuário (se `DOCKER_ROOTLESS=1`, o padrão). Se `dockerd-rootless-setuptool.sh check` falhar, **para com o motivo**; não existe alternativa com o socket de root.
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

## Operação

- **Ver o estado:** `./registrar.sh --vps root@<vps> --nome <nome> --status` (usuário, serviços, limites, registro e a última linha do log).
- **Administrar na VPS:** `sudo -u runner-<nome> …` e `systemctl --user -M runner-<nome>@ status runner-vps`.
- **Mudar limites ou extras:** `./registrar.sh … --sem-token --var MEMORY_MAX_MB=3072` (só reescreve o que mudou e faz `daemon-reload`).
- **Se o runner cair:** os jobs ficam em *Waiting for a runner* e o GitHub os cancela em 24 h. Troque `CI_RUNS_ON` para voltar aos runners do GitHub enquanto resolve, ou reinicie: `systemctl --user -M runner-<nome>@ restart runner-vps`. Causa comum: **disco cheio**; limpe como o usuário do runner com `docker system prune -af`.
- **Remover:** `./registrar.sh … --repo <dono>/<repo> --nome <nome> --remover`. Apaga o HOME, o `.conf`, a fatia e a linha do `/etc/hosts`; o usuário só é apagado se não houver arquivo dele fora do HOME; as linhas de `/etc/subuid` ficam. Se o `config.sh remove` falhar (token de remoção expirado, por exemplo), nada é apagado.

## Limites conhecidos

- Em `pull_request`, o GitHub roda o workflow **da branch do PR**: quem tem escrita no repositório executa o que quiser no runner. A defesa é o runner não ter nada de valor e não alcançar nada de valor; não é isolamento perfeito. Não use em repositório público que aceite PR de desconhecidos sem aprovação.
- Workflows com segredos de valor (deploys, chaves SSH) **ficam nos runners do GitHub**, a não ser que você aceite que esses segredos passem pela VPS.
- Um runner executa um job por vez.
- Nunca dê ao runner o socket do Docker de root. Se o rootless não funcionar na sua VPS, use outra máquina.

## Pendências

- **Repositório apt do Docker:** o instalador **não** o configura. Em uma VPS sem Docker, configure antes o repositório oficial ([docs.docker.com/engine/install](https://docs.docker.com/engine/install)) ou o instalador para depois do `apt install`, dizendo isso.
- **Primeira instalação real:** `useradd`, `systemctl --user -M`, `loginctl` e o Docker rootless só foram exercitados por comandos falsos. Rode `--so-checar` e acompanhe a primeira instalação.
- O log do gancho não registra a duração do job (exigiria um gancho de início de job).

## Testes

```bash
testes/rodar.sh                        # todos os testes (bash puro, sem rede, sem Docker, sem root)
shellcheck -S warning *.sh testes/*.sh
```

A CI do projeto (`.github/workflows/ci.yml`) roda os dois.

## Licença

MIT. Veja [LICENSE](LICENSE).
