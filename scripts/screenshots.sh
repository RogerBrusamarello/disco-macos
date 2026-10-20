#!/bin/zsh
# Tira os prints do README nos temas claro e escuro, em 2x, a partir do Disco instalado em /Applications:
# janela (Visão geral com as listas de memória e de disco, o detalhe do maior item, Limpeza, Atualizações, Ajustes) e o painel da barra de menus,
# mais o painel claro/escuro lado a lado.
# Precisa de acesso de Acessibilidade para o Terminal (mover a janela e abrir o painel).
# Uso: ./scripts/screenshots.sh [pasta de saída]   (padrão: build/screenshots)
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-build/screenshots}
mkdir -p "$OUT"

wins() {
    osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
        var l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)), r = [];
        for (var i = 0; i < l.count; i++) {
            var w = l.objectAtIndex(i);
            if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) == "Disco")
                r.push(ObjC.unwrap(w.objectForKey("kCGWindowNumber")) + " " + ObjC.unwrap(w.objectForKey("kCGWindowLayer")));
        }
        r.join("\n")'
}
# Popover aberto pela janela: "x y largura altura", em pontos da tela.
popover() {
    osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
        var l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)), r = "";
        for (var i = 0; i < l.count; i++) {
            var w = l.objectAtIndex(i), b = ObjC.deepUnwrap(w.objectForKey("kCGWindowBounds"));
            if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) == "Disco" && ObjC.unwrap(w.objectForKey("kCGWindowLayer")) == 0 && b.Width != 560)
                r = [b.X, b.Y, b.Width, b.Height].join(" ");
        }
        r'
}
click() { osascript -e "tell application \"System Events\" to tell process \"Disco\" to click at {$1, $2}" >/dev/null; }
front() { osascript -e 'tell application "System Events" to set frontmost of process "Disco" to true' >/dev/null; sleep 0.7; }
AX='tell application "System Events" to tell process "Disco" to perform action "AXPress" of menu bar item 1 of menu bar 1'

for THEME in light dark; do
    pkill -x Disco; sleep 1
    # Tema da janela pelo argumento (não mexe na escolha salva); o painel segue a aparência do app.
    AQUA=$([ $THEME = dark ] && echo NO || echo YES)
    open -a /Applications/Disco.app --args -windowTheme $THEME -NSRequiresAquaSystemAppearance $AQUA
    sleep 4
    # A tela principal (Retina) fica na origem: a janela vai para lá para o print sair em 2x.
    osascript -e 'tell application "System Events" to tell process "Disco" to set position of window 1 to {300, 120}'
    sleep 1
    W=$(wins | awk '$2==0 { print $1; exit }')
    front; screencapture -x -o -l $W "$OUT/visao-geral-$THEME.png"
    # Lista do disco: a medição leva até ~30 s.
    open "discowidget://space"; sleep 30
    front; screencapture -x -o -l $W "$OUT/visao-geral-disco-$THEME.png"
    # Detalhe do maior item, com a maior parte aberta. Só clica em nomes (a linha e a parte), nunca nas lixeiras;
    # se algo sair do lugar e abrir uma confirmação, o Esc no fim cancela.
    click 450 461; sleep 1.5
    read PX PY PW PH <<< "$(popover)"
    if [ -n "${PX:-}" ]; then
        click $((PX + 90)) $((PY + 69)); sleep 1
        read PX PY PW PH <<< "$(popover)"
        screencapture -x -o -l $W "$OUT/detalhe-tela-$THEME.png"
        python3 - "$OUT/detalhe-tela-$THEME.png" "$OUT/detalhe-$THEME.png" $(((PX - 300) * 2)) $(((PY - 120) * 2)) $((PW * 2)) $((PH * 2)) <<'PY' || echo "Sem Pillow: o detalhe não foi recortado."
import sys
from PIL import Image
src, dst, x, y, w, h = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:])
Image.open(src).crop((x, y, x + w, y + h)).save(dst, optimize=True)
PY
        rm -f "$OUT/detalhe-tela-$THEME.png"
    fi
    osascript -e 'tell application "System Events" to key code 53'; sleep 0.5
    open "discowidget://clean"; sleep 6
    front; screencapture -x -o -l $W "$OUT/limpeza-$THEME.png"
    open "discowidget://updates"; sleep 5
    front; screencapture -x -o -l $W "$OUT/atualizacoes-$THEME.png"
    open "discowidget://settings"; sleep 2
    front; screencapture -x -o -l $W "$OUT/ajustes-$THEME.png"

    # Com dois monitores o painel pode abrir no externo (1x): tenta de novo até sair em 2x (640 px).
    for _ in 1 2 3 4 5 6; do
        osascript -e "$AX" >/dev/null; sleep 2
        P=$(wins | awk '$2==101 { print $1; exit }')
        [ -z "$P" ] && continue
        screencapture -x -o -l $P "$OUT/painel-$THEME.png"
        osascript -e "$AX" >/dev/null
        [ "$(sips -g pixelWidth "$OUT/painel-$THEME.png" | tail -1 | awk '{print $2}')" = 640 ] && break
        sleep 1
    done
done

pkill -x Disco; sleep 1
open /Applications/Disco.app

# Painel escuro e claro lado a lado, sobre cinza (precisa do Pillow: pip3 install pillow).
python3 - "$OUT" <<'EOF' || echo "Sem Pillow: o painel lado a lado não foi montado."
import sys
from PIL import Image
out = sys.argv[1]
d, l = Image.open(f"{out}/painel-dark.png"), Image.open(f"{out}/painel-light.png")
c = Image.new("RGBA", (40 + d.width + 40 + l.width + 40, 40 + max(d.height, l.height) + 40), (128, 128, 128, 255))
c.paste(d, (40, 40), d)
c.paste(l, (40 + d.width + 40, 40), l)
c.save(f"{out}/painel-claro-escuro.png", optimize=True)
EOF

ls -1 "$OUT"
