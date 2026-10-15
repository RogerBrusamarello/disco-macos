#!/bin/zsh
# Release do Disco: gera o Disco.dmg a partir de uma tag e publica no GitHub.
# Normalmente quem chama é o hook .githooks/pre-push, ao dar push de uma tag vX.Y. À mão:
#   ./scripts/release.sh dmg <ref>       compila o commit <ref> (tag, branch, HEAD) e gera build/release/Disco.dmg
#   ./scripts/release.sh draft <tag>     gera o .dmg e cria o release como rascunho, com o .dmg anexado
#   ./scripts/release.sh publish <tag>   espera a tag chegar no GitHub e publica o rascunho
# DISCO_RELEASE_DRY_RUN=1 mostra os comandos do gh em vez de rodar.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$ROOT/build/release
REPO=RogerBrusamarello/disco-macos
REQUIREMENT='identifier "br.com.attodev.disco" and anchor apple generic and certificate leaf[subject.OU] = "HM8VRSUTC3"'

say() { print -P "%F{magenta}disco release%f $*"; }
die() { print -P "%F{red}disco release:%f $*" >&2; exit 1; }
gh_run() {
    if [[ -n ${DISCO_RELEASE_DRY_RUN:-} ]]; then print "[dry-run] gh $*"; else gh "$@"; fi
}

# Versão (MARKETING_VERSION) do project.yml no commit <ref>.
version_at() { git show "$1^{commit}:project.yml" | awk -F'"' '/MARKETING_VERSION/ { print $2; exit }'; }

# Compila <ref> numa cópia limpa (worktree), sem as mudanças não commitadas, e monta o .dmg.
build_dmg() {
    local ref=$1 version src app
    version=$(version_at "$ref")
    [[ -n $version ]] || die "não achei MARKETING_VERSION no project.yml de $ref"
    src=$OUT/src
    mkdir -p "$OUT"
    git worktree remove --force "$src" 2>/dev/null || rm -rf "$src"
    git worktree prune
    git worktree add --detach --quiet "$src" "$ref^{commit}"

    say "compilando $ref (versão $version)…"
    (cd "$src" && xcodegen generate >/dev/null)
    xcodebuild -project "$src/Disco.xcodeproj" -scheme Disco -configuration Release \
        -derivedDataPath "$OUT/derived" build > "$OUT/xcodebuild.log" 2>&1 \
        || { grep -E "error:" "$OUT/xcodebuild.log" | head -20 >&2; die "falha ao compilar (log em build/release/xcodebuild.log)"; }
    app=$OUT/derived/Build/Products/Release/Disco.app
    git worktree remove --force "$src"

    [[ $(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString) == "$version" ]] \
        || die "o app compilado não está na versão $version"
    codesign --verify --deep --strict -R="$REQUIREMENT" "$app" \
        || die "assinatura do app não confere (precisa do certificado do time HM8VRSUTC3)"

    say "montando o Disco.dmg…"
    make_dmg "$app" "$OUT/Disco.dmg"
    say "pronto: build/release/Disco.dmg ($(du -h "$OUT/Disco.dmg" | cut -f1 | xargs))"
}

# Mesmo visual do .dmg da 1.3: fundo da marca em 660×400 (+28 da barra de título, para a legenda de baixo
# aparecer inteira), app à esquerda e Aplicativos à direita.
make_dmg() {
    local app=$1 dmg=$2 rw=$OUT/rw.dmg vol=/Volumes/Disco bg=$OUT/background
    [[ -d $vol ]] && die "já existe um volume \"Disco\" montado; ejete e rode de novo"
    rm -f "$rw" "$dmg"
    hdiutil create -size 64m -fs HFS+ -volname Disco -ov "$rw" -quiet
    hdiutil attach "$rw" -noautoopen -mountpoint "$vol" -quiet
    {
        ditto "$app" "$vol/Disco.app"
        ln -s /Applications "$vol/Applications"
        mkdir -p "$vol/.background" "$bg"
        sips -z 400 660 "$ROOT/brand/dmg-background.png" --out "$bg/bg.png" >/dev/null
        cp "$ROOT/brand/dmg-background.png" "$bg/bg@2x.png"
        tiffutil -cathidpicheck "$bg/bg.png" "$bg/bg@2x.png" -out "$vol/.background/background.tiff" 2>/dev/null
        osascript >/dev/null <<'EOF'
tell application "Finder"
    tell disk "Disco"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set options to icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 112
        set text size of options to 12
        set background picture of options to file ".background:background.tiff"
        set position of item "Disco.app" of container window to {180, 220}
        set position of item "Applications" of container window to {480, 220}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
        sync
    } always {
        hdiutil detach "$vol" -quiet || hdiutil detach "$vol" -force -quiet
    }
    hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg" -quiet
    rm -f "$rw"
}

# Título e notas: de uma tag anotada (`git tag -a v1.4`), a primeira linha vira o título e o resto as notas.
# Tag simples: "Disco X.Y" e a lista de commits desde a tag anterior.
release_notes() {
    local tag=$1 version=$2 notes=$OUT/notes.md subject body previous
    subject=$(git tag -l --format='%(contents:subject)' "$tag")
    body=$(git tag -l --format='%(contents:body)' "$tag")
    if [[ $(git cat-file -t "$tag") == tag && -n $subject ]]; then
        TITLE=$subject
        print -r -- "$body" > "$notes"
    else
        TITLE="Disco $version"
        previous=$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)
        {
            print "## Novidades\n"
            git log --no-merges --format='- %s' "${previous:+$previous..}$tag"
        } > "$notes"
    fi
    print -r -- "
**Instalação:** abra o .dmg e arraste o Disco para Aplicativos. Na primeira vez, libere em Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim. Requer macOS 14 ou mais recente. Da 1.4 em diante, o Disco se atualiza sozinho." >> "$notes"
    NOTES=$notes
}

draft() {
    local tag=$1 version=${1#v}
    [[ $(version_at "$tag") == "$version" ]] \
        || die "a tag $tag não bate com MARKETING_VERSION \"$(version_at "$tag")\" do project.yml. Suba a versão antes de criar a tag."
    gh release view "$tag" -R $REPO >/dev/null 2>&1 && die "o release $tag já existe no GitHub"
    build_dmg "$tag"
    release_notes "$tag" "$version"
    say "criando o rascunho do release $tag…"
    gh_run release create "$tag" "$OUT/Disco.dmg" -R $REPO --draft \
        --target "$(git rev-parse "$tag^{commit}")" --title "$TITLE" --notes-file "$NOTES"
}

# Publica só depois que a tag existe no GitHub; se publicasse antes, o GitHub criaria a tag e o push dela falharia.
publish() {
    local tag=$1
    [[ -n ${DISCO_RELEASE_DRY_RUN:-} ]] && { gh_run release edit "$tag" -R $REPO --draft=false --latest; return; }
    for _ in {1..120}; do
        git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && break
        sleep 5
    done
    git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 \
        || { notify "A tag $tag não chegou no GitHub. O release ficou como rascunho."; die "tag $tag não chegou no GitHub"; }
    gh_run release edit "$tag" -R $REPO --draft=false --latest
    say "release $tag publicado"
    notify "Release $tag publicado. Os apps instalados acham a versão nova em até um dia."
}

notify() { osascript -e "display notification \"$1\" with title \"Disco\"" >/dev/null 2>&1 || true; }

case ${1:-} in
    dmg) build_dmg "${2:-HEAD}" ;;
    draft) draft "${2:?uso: release.sh draft vX.Y}" ;;
    publish) publish "${2:?uso: release.sh publish vX.Y}" ;;
    *) die "uso: release.sh dmg [ref] | draft vX.Y | publish vX.Y" ;;
esac
