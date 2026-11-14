# runner-vps

Instala um runner self-hosted do GitHub Actions numa VPS Linux, de forma segura e repetível, para **qualquer** repositório ou organização. Serve para quem esgota os minutos do plano gratuito do GitHub Actions e já tem uma VPS.

O runner roda num usuário próprio, **sem sudo e sem o grupo `docker`**, com um Docker **rootless** separado (opcional, ligado por padrão), dentro de uma fatia do systemd com limites de memória e CPU. Um PR malicioso ou errado não consegue chegar aos contêineres, aos arquivos nem aos segredos do resto da VPS.

Situação: **em planejamento**. O desenho está em [docs/design.md](docs/design.md) e as tasks de implementação em [docs/plano.md](docs/plano.md). Os scripts ainda não existem.

## O que o instalador fará

```
ssh root@<vps> 'RUNNER_URL=https://github.com/<dono>/<repo> RUNNER_NOME=<nome> RUNNER_TOKEN=<token> bash -s' < instalar.sh
```

1. Diagnostica a VPS e para com `VEREDITO: não cabe` se não sobrar memória, CPU ou disco.
2. Cria o usuário `runner-<nome>`, sem privilégio, com `linger` ligado.
3. Instala o Docker rootless desse usuário (se `DOCKER_ROOTLESS=1`, o padrão).
4. Baixa o runner do GitHub com versão e sha256 fixos e o registra com o token (uso único, nunca gravado).
5. Grava a unidade `systemd --user`, os limites da fatia, o gancho de limpeza e a configuração em `/etc/runner-vps/<nome>.conf`.
6. Liga tudo e imprime o estado.

Rodar de novo não muda nada se nada mudou. `--so-checar` só diagnostica; `--status` mostra; `--remover` desfaz.

Uma VPS pode ter várias instâncias (um `RUNNER_NOME` por repositório), cada uma com usuário, Docker e limites próprios.

## No repositório que vai usar o runner

Troque, em cada job do workflow:

```yaml
runs-on: ${{ vars.CI_RUNS_ON && fromJSON(vars.CI_RUNS_ON) || 'ubuntu-latest' }}
```

e crie a variável de repositório `CI_RUNS_ON` com `["self-hosted","linux","<rótulo>"]`. Para voltar aos runners do GitHub, grave `"ubuntu-latest"` (com aspas) ou apague a variável. Passos que só valem no runner do GitHub (por exemplo `sudo`) ganham `if: runner.environment == 'github-hosted'`. Detalhes em [docs/design.md](docs/design.md#45-o-que-muda-no-repositório-que-usa-o-runner).

## Limites conhecidos

- Em `pull_request`, o GitHub roda o workflow **da branch do PR**: quem tem escrita no repositório executa o que quiser no runner. A defesa é o runner não ter nada de valor e não alcançar nada de valor; não é isolamento perfeito. Não use em repositório público que aceite PR de desconhecidos sem aprovação.
- Um runner executa um job por vez.
- Nunca dê ao runner o socket do Docker de root. Se o rootless não funcionar na sua VPS, use outra máquina.

## Licença

MIT. Veja [LICENSE](LICENSE).
