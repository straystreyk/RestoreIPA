#!/bin/bash
# Сборка Restore для macOS: dist/Restore.app и dist/Restore-<версия>-macos-<arm64|intel>.dmg.
# Архитектура — как у Python, которым запущена сборка (на Apple Silicon — arm64, на Intel — x86_64).
#
#   bash build_mac.sh
#
# Нужно: Python 3.12 (python3.12 в PATH или переменная PYTHON), Go и Xcode Command Line Tools
# (iconutil, codesign, hdiutil). ipatool собирается из закреплённого официального commit; исходный архив и
# результат сборки сверяются по SHA-256.
set -euo pipefail
cd "$(dirname "$0")"

IPATOOL_COMMIT="001d889896fcb118546443c5dfe0997d11b74f56"  # PR #643: новый native auth + Store AMD proofs
IPATOOL_VERSION="2.8.0-dev.001d889"
IPATOOL_SOURCE_SHA="8b61a6925409a2fb669be92d83df6bfae7a8ccfbb03f567fe7ec80240934dd11"
IPATOOL_BIN_SHA_arm64="9410bfe8bec66cbf3bf46402c4e0a53b3024a06278fe02ba1eeafdd313ad16f6"
IPATOOL_BIN_SHA_amd64="8fe826175b27667058b8e31f72b5aefaf8fd224003f59efb9554fd406b26515b"
GO_VERSION="1.26.5"

PYTHON="${PYTHON:-python3.12}"
ARCH="$("$PYTHON" -c 'import platform; print(platform.machine())')"
case "$ARCH" in
    arm64) IPA_ARCH=arm64; LABEL=arm64 ;;
    x86_64) IPA_ARCH=amd64; LABEL=intel ;;
    *) echo "Неизвестная архитектура: $ARCH" >&2; exit 1 ;;
esac
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' restore_apps.py)"
echo "Restore $VERSION для macOS ($ARCH)"

# --- окружение сборки ---
if [ ! -x build/venv/bin/python ]; then
    echo "Создаю build/venv"
    "$PYTHON" -m venv build/venv
fi
PY=build/venv/bin/python
if [ "$ARCH" = "x86_64" ]; then
    # для Intel готовой сборки cryptography нет — pip собирает её из исходников с OpenSSL из Homebrew. Собираем со
    # встроенным (статическим) OpenSSL: иначе её libssl.3.dylib в .app совпадает по имени со старой копией Python
    # и cryptography не загружается (Symbol not found: _SSL_get0_group_name).
    # Другой OpenSSL для x86_64 (например, собранный на Mac с процессором Apple) — переменной OPENSSL_DIR
    OPENSSL_DIR="${OPENSSL_DIR:-$(brew --prefix openssl@3)}"
    export OPENSSL_DIR OPENSSL_STATIC=1
    # пути к исходникам Rust-пакетов попадают в собранную библиотеку: домашняя папка заменяется нейтральным путём,
    # а собранное раньше pip берёт не из кэша, а собирает заново
    export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/build-home"
    export PIP_NO_CACHE_DIR=1
fi
# все пакеты сборки — точные версии с SHA-256 (requirements-lock.txt собран из requirements-build.txt, см. README)
"$PY" -m pip install --disable-pip-version-check -q --require-hashes -r requirements-lock.txt

# --- ipatool для Mac из официального исходного кода ---
command -v go >/dev/null || { echo "Не найден Go. Установите: brew install go" >&2; exit 1; }
ACTUAL_GO="$(GOTOOLCHAIN="go$GO_VERSION" go env GOVERSION)"
[ "$ACTUAL_GO" = "go$GO_VERSION" ] || { echo "Нужен Go $GO_VERSION, найден $ACTUAL_GO" >&2; exit 1; }
mkdir -p build/dl build/res build/src
TAR="build/dl/ipatool-$IPATOOL_COMMIT-source.tar.gz"
if [ ! -f "$TAR" ] || [ "$(shasum -a 256 "$TAR" | cut -d' ' -f1)" != "$IPATOOL_SOURCE_SHA" ]; then
    echo "Скачиваю исходники ipatool $IPATOOL_VERSION"
    curl -fsSL -o "$TAR" "https://github.com/majd/ipatool/archive/$IPATOOL_COMMIT.tar.gz"
fi
GOT="$(shasum -a 256 "$TAR" | cut -d' ' -f1)"
if [ "$GOT" != "$IPATOOL_SOURCE_SHA" ]; then
    echo "SHA-256 не совпал: $TAR"$'\n'"  ожидался $IPATOOL_SOURCE_SHA"$'\n'"  получен  $GOT" >&2
    exit 1
fi
rm -rf build/src/ipatool && mkdir -p build/src/ipatool
tar -xzf "$TAR" -C build/src/ipatool --strip-components=1
echo "Собираю ipatool $IPATOOL_VERSION ($IPA_ARCH)"
(
    cd build/src/ipatool
    GOTOOLCHAIN="go$GO_VERSION" GOOS=darwin GOARCH="$IPA_ARCH" CGO_ENABLED=1 \
        CGO_CFLAGS="-mmacosx-version-min=10.15" CGO_LDFLAGS="-mmacosx-version-min=10.15" \
        go build -buildvcs=false -trimpath \
        -ldflags="-X=github.com/majd/ipatool/v2/cmd.version=$IPATOOL_VERSION" -o ../../res/ipatool .
)
BIN_SHA_VAR="IPATOOL_BIN_SHA_$IPA_ARCH"
GOT="$(shasum -a 256 build/res/ipatool | cut -d' ' -f1)"
if [ "$GOT" != "${!BIN_SHA_VAR}" ]; then
    echo "SHA-256 собранного ipatool не совпал"$'\n'"  ожидался ${!BIN_SHA_VAR}"$'\n'"  получен  $GOT" >&2
    exit 1
fi
build/res/ipatool --version

# --- иконка .icns из того же рисунка, что и icon.ico (installer/make_art.py) ---
rm -rf build/res/icon.iconset && mkdir -p build/res/icon.iconset
QT_QPA_PLATFORM=offscreen "$PY" - <<'PYEOF'
import sys
sys.path.insert(0, "installer")
from PySide6.QtGui import QGuiApplication
import make_art
app = QGuiApplication([])
for s in (16, 32, 128, 256, 512):
    make_art.icon(s).save(f"build/res/icon.iconset/icon_{s}x{s}.png")
    make_art.icon(s * 2).save(f"build/res/icon.iconset/icon_{s}x{s}@2x.png")
PYEOF
iconutil -c icns build/res/icon.iconset -o build/res/icon.icns

# --- тесты: сломанную логику не собираем ---
echo "Тесты"
QT_QPA_PLATFORM=offscreen "$PY" -m unittest discover -s tests -q

# --- Restore.app ---
rm -rf dist/Restore.app dist/RestoreAppStore build/RestoreAppStore
"$PY" -m PyInstaller --noconfirm --clean RestoreAppStore.spec
APP=dist/Restore.app
EXE="$APP/Contents/MacOS/RestoreAppStore"

# интерфейс загружается (если из Qt вырезано что-то нужное — сборка остановится)
echo "Интерфейс загружается: $EXE"
REPORT="$(mktemp)"
QT_QPA_PLATFORM=offscreen "$EXE" --check-ui "$REPORT" || { cat "$REPORT"; exit 1; }
# встроенный установщик (pymobiledevice3) запускается (`--help` не годится: справка грузит все команды,
# в т.ч. ненужные программе, и падает в собранной версии — и на Windows тоже)
"$EXE" --pmd version
# cryptography не должна тянуть отдельные libssl/libcrypto (см. выше про Intel)
if otool -L "$APP"/Contents/Frameworks/cryptography/hazmat/bindings/_rust*.so | grep -q 'libssl\|libcrypto'; then
    echo "cryptography собрана с внешним OpenSSL — в .app возможен конфликт библиотек" >&2
    exit 1
fi

# подпись без сертификата (ad-hoc) PyInstaller ставит сам: без неё Apple Silicon не запустит программу вовсе.
# Переподписывать codesign --deep нельзя — он спотыкается о ссылки Resources↔Frameworks внутри .app; только проверяем
BROKEN="$(find "$APP" -type l ! -exec test -e {} \; -print)"
if [ -n "$BROKEN" ]; then
    echo "Битые ссылки внутри .app (что-то вырезано фильтром DROP в RestoreAppStore.spec):"$'\n'"$BROKEN" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"
# в программе не должно быть путей к домашней папке того, кто собирает (имени пользователя этого Mac)
HOME_REFS="$(grep -rlaF "$HOME/" "$APP" || true)"
if [ -n "$HOME_REFS" ]; then
    echo "В .app есть пути к домашней папке ($HOME):"$'\n'"$HOME_REFS" >&2
    exit 1
fi

# --- образ .dmg: Restore.app и ярлык «Программы» для перетаскивания ---
DMG="dist/Restore-$VERSION-macos-$LABEL.dmg"
rm -rf build/dmg "$DMG" && mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Restore $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cat "$DMG.sha256"
echo "Готово: $DMG"
