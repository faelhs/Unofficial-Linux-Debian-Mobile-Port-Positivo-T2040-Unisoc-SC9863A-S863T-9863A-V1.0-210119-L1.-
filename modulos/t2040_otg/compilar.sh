#!/bin/bash
# Compila o t2040_otg.ko contra o kernel do kernel/compilar-kernel.sh (rode esse antes).
# O Kbuild nao aceita espaco no caminho: compila numa copia em $TRAB/mod-otg.
set -e
AQUI=$(cd "$(dirname "$0")" && pwd)
TRAB=${TRAB:-$HOME/t2040-kernel}
CL=$TRAB/clang-r383902b/bin
[ -f "$TRAB/out/Module.symvers" ] || { echo "falta $TRAB/out: rode antes o kernel/compilar-kernel.sh"; exit 1; }
B=$TRAB/mod-otg
mkdir -p "$B"
cp "$AQUI/t2040_otg.c" "$AQUI/Kbuild" "$B/"
make -C "$TRAB/fonte" O="$TRAB/out" M="$B" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION= \
	CC=$CL/clang HOSTCC=gcc CLANG_TRIPLE=arm-linux-gnueabi- LD=$CL/ld.lld TARGET_BUILD_VARIANT=user modules
echo "Modulo pronto: $B/t2040_otg.ko (na imagem fica em /usr/lib/t2040/modules/otg/)"
