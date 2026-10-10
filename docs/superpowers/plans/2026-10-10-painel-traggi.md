# Painel do Traggi na conversa do CRM: plano de implementação

**Spec:** `docs/superpowers/specs/2026-10-10-painel-traggi-design.md`

**Execução:** inline, com TDD. O Traggi não recebe commit até o usuário pedir. Os repositórios do CRM recebem commit e push em `feature/painel-traggi`.

## Restrições globais

- Traggi:
  - seguir os padrões existentes;
  - não mudar o comportamento atual;
  - nada de dependências novas e nada de segredos no código;
  - LGPD: só o necessário, nunca e-mail, CPF ou pagamento;
  - fuso America/Sao_Paulo.
- CRM:
  - marcar as alterações com `[Traggi]`;
  - specs no `traggi-specs.yml` (não há Ruby local);
  - i18n com paridade en/pt-BR.

## Tarefas

1. **Traggi: `App\Agente\PainelCrm`** (classe pura) + `PainelCrmTest`.
   - `acoesLead(status)`, `acoesCliente(status, opt_out)` e `iaRespondendo(tipo, status, opt_out, ia_ligada, liberado)`.
   - Registrar em `carregar.php`.
2. **Traggi: `Agente_crm_painel_service`** (`situacao`, `acao`), as rotas `crm_situacao`/`crm_acao` no `Api_agente` e o `routes.php`.
   - Testes no `api_local.sh`, seção "painel do CRM".
3. **CRM backend: `Traggi::Client`** + `client_spec.rb` (WebMock).
4. **CRM backend: `Conversations::TraggiController`** + rotas + `traggi_spec.rb`.
   - Acrescentar as specs ao `traggi-specs.yml`.
   - Push da branch e conferência do CI.
5. **CRM frontend: `traggiService`, `TraggiPanel` e i18n** + `TraggiPanel.spec.tsx`.
   - Plugar no `ContactSidebar`.
   - Rodar vitest, tsc e eslint.
   - Push da branch.
6. **Verificação final:**
   - suíte do Traggi (PHPUnit, `api_local`);
   - CI do CRM verde;
   - guia de deploy do Traggi;
   - revisão de todo o diff.
