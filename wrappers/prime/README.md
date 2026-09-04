# Prime Agent Leash

Este diretório contém o *leash* (guia/coleira) para sessões do **Prime Agent** no ecossistema HMVIP.

O Prime Agent não substitui um binário CLI como Kimi/CodeWhale; portanto, em vez de um wrapper que intercepta uma chamada de executável, fornecemos um script shell que deve ser **sourcado** antes de iniciar o Prime Agent. Ele:

1. Detecta a raiz do repositório HMVIP.
2. Executa `source .hmvip-agent-init prime<N> ia-a` para alugar um slot Prime.
3. Exporta as variáveis de ambiente necessárias (`AGENT_GUARD_IDENTITY`, `AGENT_GUARD_WORKTREE_PATH`, `AGENT_GUARD_BRANCH`, etc.).

## Uso

```bash
cd /home/hmvip-dev/hmvip
source packages/agent-guard-core/wrappers/prime/leash.sh prime1 ia-a
```

Depois de sourcado, inicie o Prime Agent no mesmo shell; as variáveis de lease serão herdadas.

## Identidades

A identidade `prime` foi adicionada a `agent-guard.yaml` com:

- `slots: 3` (prime1, prime2, prime3)
- `max_slots: 10`
- `auto_expand: true`
- prefixo de worktree: `hmvip-ia-prime`
