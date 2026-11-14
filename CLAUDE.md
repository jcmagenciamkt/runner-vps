# runner-vps — instruções para agentes

Scripts em bash que instalam um runner self-hosted do GitHub Actions numa VPS Linux, de forma **agnóstica**: nada aqui sabe de um repositório ou de uma VPS específica. Repositório **público**.

## Comece aqui
1. Leia `docs/design.md` (a spec; ela prevalece) e `docs/plano.md` (as tasks, com os testes de cada uma).
2. `README.md` é o manual do usuário final. `AGENTS.md` repete este arquivo para outros agentes.
3. Trabalhe task por task, na ordem do plano, com os testes primeiro: escreva o teste, veja falhar, implemente, veja passar. Um commit por parte.

## Regras invioláveis
- **`RUNNER_TOKEN` nunca aparece** em saída, log, arquivo, mensagem de erro, `set -x` ou linha de comando (`ps`). Todo caminho que recebe o token tem um teste que afirma a ausência dele.
- **Nenhum dado real** de VPS ou repositório: nada de IP (só `127.0.0.1`), domínio, usuário, porta SSH, nome de projeto. Exemplos usam `<vps>`, `<dono>/<repo>`, `exemplo`.
- **Nenhum agente roda `instalar.sh`, `registrar.sh` nem `gancho-fim.sh` contra uma VPS real, nem chama a API do GitHub com a conta do usuário.** Os testes substituem `gh`, `ssh`, `systemctl`, `apt-get`, `docker` e afins por comandos falsos (variáveis `*_CMD`). Sem rede, sem Docker, sem root.
- **Nunca** dar ao runner o socket do Docker de root (`/var/run/docker.sock`), `sudo` ou o grupo `docker`. Se o rootless não servir, a resposta é "não cabe", não um contorno.
- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, função `passo()`, idempotentes, mensagens em **português do Brasil**, `shellcheck -S warning` limpo.
- Nunca apagar nem enfraquecer teste para fazê-lo passar. Nunca push direto na `main`: branch + PR, com CI verde.
- Versões baixadas da internet têm sha256 fixo no script.

## Verificação
```bash
testes/rodar.sh          # todos os testes (bash puro, sem dependências)
shellcheck -S warning *.sh testes/*.sh
```
O CI do projeto (`.github/workflows/ci.yml`) roda os dois. Rode antes de abrir ou atualizar um PR.

## Estrutura
- `instalar.sh` — roda **na VPS, como root**, enviado por `ssh … 'bash -s'`. Subcomandos `--so-checar`, `--status`, `--remover`.
- `registrar.sh` — roda **na máquina de quem administra**. Gera o token pela API (`gh api`), monta as variáveis e envia o `instalar.sh` pelo SSH. O token vai pelo fluxo de entrada do SSH, nunca pela linha de comando.
- `gancho-fim.sh` — roda na VPS, como o usuário do runner, ao fim de cada job.
- Os modelos da unidade systemd e dos limites ficam **dentro** do `instalar.sh` (ele viaja sozinho pelo stdin do SSH). `testes/` — harness e testes. `docs/` — spec e plano.

## Quando travar
Spec ambígua ou task contraditória: faça a escolha mais simples que respeite a spec e explique no relato do PR. Se estiver bloqueado de verdade, pare e pergunte, com as opções e a sua recomendação.
