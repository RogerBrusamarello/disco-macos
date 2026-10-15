# AGENTS.md

Regras para quem mexe no Disco, pessoa ou agente.

## Toda mudança atualiza o README

**Toda e qualquer mudança no projeto tem que mudar o [README.md](README.md), no mesmo commit.** Não existe mudança "pequena demais" para o README: se o código mudou, o README é revisado e atualizado junto.

O que conferir a cada mudança:

- **Texto:** a seção certa descreve o comportamento novo (O que o disco faz, Janela, Abduzir temporários, Atualizações, Barra de menus, Widgets, Instalação, Como funciona, Compilar, Estrutura). Textos, nomes de botões e números (intervalos, limites, tamanhos) iguais aos do app.
- **Imagens:** se a mudança aparece na interface, refaça os prints afetados:
  1. Instale a versão nova com `./scripts/install.sh`.
  2. Rode `./scripts/screenshots.sh` (saída em `build/screenshots`): janela e painel, temas claro e escuro, em 2x.
  3. Copie para `docs/readme/` **com nomes novos** e apague os antigos. O GitHub guarda as imagens em cache pelo nome, e com o mesmo nome o README continua mostrando a imagem velha.
  4. Atualize os caminhos e os textos `alt` no README.
- **Versão:** ao subir `MARKETING_VERSION` no `project.yml`, atualize a versão na linha de download do README.
- **Estrutura:** arquivo, pasta ou script novo entra no bloco "Estrutura".

## Publicar uma versão para os apps instalados

Commit e push na `main` **não chegam** em quem já tem o Disco instalado: os apps só se atualizam quando sai um release novo no GitHub. Quando pedirem para lançar, publicar ou "mandar para todo mundo" uma mudança, faça o fluxo inteiro:

1. **Hook ativo:** `git config core.hooksPath` tem que responder `.githooks`. Se não responder, rode `git config core.hooksPath .githooks`. Sem o hook, o push da tag não gera o release.
2. **Versão:** em `project.yml`, suba `MARKETING_VERSION` (maior que a do último release, comparada como número: 1.10 > 1.9) e `CURRENT_PROJECT_VERSION` (+1). Atualize a versão na linha de download do README.
3. **Commit** com a versão e o README. Só entra no release o que está commitado: a tag é compilada numa cópia limpa, sem as mudanças não commitadas (inclusive as de outra sessão).
4. **Tag anotada** `vX.Y`, igual ao `MARKETING_VERSION`, no commit da versão. A primeira linha é o título, no padrão dos anteriores (`Disco 1.4 — atualiza sozinho 🛸`). Depois vem `## Novidades`, com um item por mudança, em português e escrito para quem usa o app: essas notas aparecem no aviso de atualização e na aba Atualizações.
   ```bash
   git tag -a vX.Y -m "Disco X.Y — subtítulo 🛸" -m "## Novidades

   - **Item:** o que mudou para quem usa."
   ```
5. **Push:** `git push origin main vX.Y`. O hook confere a versão, compila, monta o `Disco.dmg`, cria o rascunho e, depois do push, publica. Se falhar, nada vai para o GitHub: corrija e repita o mesmo push.
6. **Conferir:** `gh release list -R RogerBrusamarello/disco-macos` mostra `vX.Y` como **Latest** (não Draft), e `gh release view vX.Y -R RogerBrusamarello/disco-macos` lista o `Disco.dmg`. O log da publicação fica em `build/release/publish-vX.Y.log`. Os apps instalados (1.4 em diante) acham a versão em até um dia, ou na hora pelo **Procurar atualizações**.

## Outras regras

- **Versão e release:** a atualização automática lê o último release do GitHub (tag `vX.Y` com o asset `Disco.dmg`). Não mude esse formato sem mudar `App/Updater.swift`, `scripts/release.sh` e as seções Atualizações e Publicar uma versão do README.
- **Publicar:** o release sai só do push da tag (hook `.githooks/pre-push` → `scripts/release.sh`). Não suba `.dmg` à mão nem crie o release pelo site: o hook confere a versão e a assinatura antes.
- **Idioma:** interface, README e mensagens de commit em português.
