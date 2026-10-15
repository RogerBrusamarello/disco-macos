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

## Outras regras

- **Versão e release:** a atualização automática lê o último release do GitHub (tag `vX.Y` com o asset `Disco.dmg`). Não mude esse formato sem mudar `App/Updater.swift` e a seção Atualizações do README.
- **Idioma:** interface, README e mensagens de commit em português.
