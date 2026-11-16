#!/bin/bash

set -euo pipefail

show_help() {
cat << EOF
Uso:

    $0 <nombre> <ruta_ejecutable>

Ejemplo:

    $0 ivanti /opt/pulsesecure/bin/pulseUI

Generará:

    ./ivanti-libs
    ./ivanti-junk

Descargará las dependencias necesarias desde un contenedor Debian 12 
para resolver automáticamente las dependencias faltantes detectadas 
mediante ldd y creará un lanzador global en /usr/local/bin.

Opciones:

    -h, --help      Mostrar esta ayuda

EOF
}

case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
esac

if [ $# -ne 2 ]; then
    show_help
    exit 1
fi

NAME="$1"
# Convertimos el target a ruta absoluta para que el lanzador global nunca falle
TARGET=$(realpath "$2")

if [ ! -f "$TARGET" ]; then
    echo "[!] El ejecutable objetivo no existe: $TARGET"
    exit 1
fi

echo "[+] Analizando dependencias faltantes iniciales en $TARGET..."

INITIAL_MISSING=$(
    ldd "$TARGET" 2>/dev/null |
    grep "not found" |
    awk '{print $1}' |
    sort -u || true
)

if [ -z "$INITIAL_MISSING" ]; then
    echo "[+] El binario no tiene dependencias faltantes. No es necesario hacer nada."
    exit 0
fi

echo "[+] Bibliotecas faltantes detectadas inicialmente:"
echo "$INITIAL_MISSING"

CTR_NAME="$NAME-bookworm-deps"

LIBDIR="$PWD/${NAME}-libs"
JUNKDIR="$PWD/${NAME}-junk"

cleanup() {
    podman rm -f "$CTR_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "[+] Limpiando directorios antiguos..."

rm -rf "$LIBDIR"
rm -rf "$JUNKDIR"

mkdir -p "$LIBDIR/usr/lib/x86_64-linux-gnu"
mkdir -p "$JUNKDIR"

echo "[+] Creando contenedor Debian 12..."

podman rm -f "$CTR_NAME" >/dev/null 2>&1 || true

podman run -d \
    --name "$CTR_NAME" \
    docker.io/library/debian:12 \
    sleep infinity >/dev/null

echo "[+] Instalando herramientas (apt-rdepends, dpkg-dev, apt-file)..."

podman exec "$CTR_NAME" bash -c '
export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    apt-rdepends \
    dpkg-dev \
    apt-file

apt-file update
'

echo "[+] Resolviendo paquetes y descargando árbol de dependencias..."

podman exec -e INITIAL_MISSING="$INITIAL_MISSING" "$CTR_NAME" bash -c '
set -euo pipefail

mkdir -p /tmp/program-debs
chown _apt:root /tmp/program-debs
chmod 755 /tmp/program-debs
cd /tmp/program-debs

ALL_PKGS=""

for LIB in $INITIAL_MISSING
do
    echo "[+] Buscando paquete contenedor para la biblioteca: $LIB"

    # Traduce el archivo .so al nombre del paquete en Debian 12
    PKG=$(
        apt-file search "$LIB" |
        awk -F": " -v lib="/$LIB" "\$2 ~ lib\"$\" {print \$1; exit}"
    )

    if [ -z "$PKG" ]; then
        echo "[!] Advertencia: No se encontró ningún paquete para $LIB en Debian 12"
        continue
    fi

    echo "[+] Calculando dependencias recursivas con apt-rdepends para: $PKG ($LIB)"

    DEPS=$(
        apt-rdepends "$PKG" 2>/dev/null |
        grep -v "^ " |
        grep -v "^PreDepends:" |
        grep -v "^Depends:" |
        sort -u
    )

    ALL_PKGS=$(printf "%s\n%s\n" "$ALL_PKGS" "$DEPS")
done

PKGS=$(echo "$ALL_PKGS" | sed "/^$/d" | sort -u)

if [ -z "$PKGS" ]; then
    echo "[!] No se pudieron resolver paquetes para descargar."
    exit 1
fi

for p in $PKGS
do
    case "$p" in
        libc6|libstdc++6|libgcc-s1|libc-bin|libgcc1)
            echo "[SKIP] $p"
            ;;
        *)
            echo "[DOWN] $p"
            apt-get download "$p" || true
            ;;
    esac
done

mkdir -p extracted

for deb in *.deb
do
    [ -f "$deb" ] || continue
    dpkg-deb -x "$deb" extracted
done
'

echo "[+] Copiando rootfs extraído a ${NAME}-junk..."

podman cp \
    "$CTR_NAME:/tmp/program-debs/extracted/." \
    "$JUNKDIR"

echo "[+] Resolviendo dependencias reales con ldd..."

export LD_LIBRARY_PATH="$LIBDIR/usr/lib/x86_64-linux-gnu"

PREV_MISSING=""

while true
do
    MISSING=$(
        ldd "$TARGET" 2>/dev/null |
        grep "not found" |
        awk '{print $1}' |
        sort -u || true
    )

    if [ -z "$MISSING" ]
    then
        break
    fi

    if [ "$MISSING" = "$PREV_MISSING" ]
    then
        echo
        echo "[!] No hay progreso en la resolución de dependencias"
        echo "[!] Dependencias pendientes:"
        echo "$MISSING"
        exit 1
    fi

    PREV_MISSING="$MISSING"

    COPIED=0

    echo
    echo "[+] Dependencias faltantes en esta iteración:"
    echo "$MISSING"
    echo

    for LIB in $MISSING
    do
        MATCHES=$(
            find "$JUNKDIR/usr/lib" "$JUNKDIR/lib" \
                -name "${LIB}*" \
                2>/dev/null || true
        )

        if [ -n "$MATCHES" ]
        then
            echo "[+] Copiando $LIB"

            while IFS= read -r FILE
            do
                [ -z "$FILE" ] && continue

                cp -a \
                    "$FILE" \
                    "$LIBDIR/usr/lib/x86_64-linux-gnu/"
            done <<< "$MATCHES"

            COPIED=1
        else
            echo "[!] No encontrado en junk: $LIB"
        fi
    done

    if [ "$COPIED" -eq 0 ]
    then
        echo
        echo "[!] No se pudo resolver ninguna dependencia adicional"
        echo "[!] Abortando"
        exit 1
    fi
done

echo
echo "[+] Dependencias resueltas correctamente"
echo

echo "[+] Bibliotecas finales copiadas:"
echo

find "$LIBDIR/usr/lib/x86_64-linux-gnu" \
    -maxdepth 1 \
    | sort

echo
echo "[+] Eliminando ${NAME}-junk..."
rm -rf "$JUNKDIR"

WRAPPER_PATH="/usr/local/bin/$NAME"

echo
echo "[+] Generando script lanzador en $WRAPPER_PATH..."

# Creamos el script en /usr/local/bin (pedirá contraseña de sudo si no está cacheada)
cat <<EOF | sudo tee "$WRAPPER_PATH" > /dev/null
#!/bin/bash

export LD_LIBRARY_PATH="$LIBDIR/usr/lib/x86_64-linux-gnu"

exec $TARGET "\$@"
EOF

sudo chmod +x "$WRAPPER_PATH"

echo
echo "[+] ¡Completado!"
echo "[+] Uso global disponible:"
echo
echo "    $NAME [argumentos...]"
echo