#!/bin/bash
# Compila o kernel do Positivo T2040 (Linux 4.14.193 ARM32) no Ubuntu ou no WSL.
#
# Fonte: kernel aberto do Realme C21Y (mesmo BSP Unisoc SC9863A) + t2040-kernel.patch.
# Compilador: Clang 11.0.2 r383902b do Android 11 (o mesmo do kernel original).
# Com esse compilador e o patch, os CRCs dos simbolos batem com os modulos .ko
# originais do tablet (Wi-Fi, GPU, toque...), que entao carregam sem forcar.
#
# Uso:  bash compilar-kernel.sh            (trabalha em ~/t2040-kernel)
# Saida: ~/t2040-kernel/out/arch/arm/boot/Image
set -euo pipefail

AQUI=$(cd "$(dirname "$0")" && pwd)
TRAB=${TRAB:-$HOME/t2040-kernel}
FONTE_COMMIT=3e85eafa35a4915079900d50834fb184a05c65db
FONTE_URL=https://github.com/realme-kernel-opensource/realme_C21Y-AndroidR-kernel-source/archive/$FONTE_COMMIT.tar.gz
FONTE_SHA256=1eef756884176711435ed56eaf602f68b9105f7a87a6a15f42b80303106b0b14
CLANG_URL=https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-11.0.0_r1/clang-r383902b.tar.gz

faltam=""
for c in make gcc bc bison flex python3 curl perl arm-linux-gnueabihf-as arm-linux-gnueabihf-objcopy; do
	command -v $c >/dev/null || faltam="$faltam $c"
done
if [ -n "$faltam" ]; then
	echo "Faltam ferramentas:$faltam"
	echo "Instale com:"
	echo "  sudo apt install build-essential bc bison flex libssl-dev libelf-dev python3 curl binutils-arm-linux-gnueabihf"
	exit 1
fi

mkdir -p "$TRAB"
cd "$TRAB"

if [ ! -d fonte ]; then
	echo "== baixando a fonte do kernel (Realme C21Y, $FONTE_COMMIT)"
	curl -fL -o fonte.tar.gz "$FONTE_URL"
	echo "$FONTE_SHA256  fonte.tar.gz" | sha256sum -c -
	mkdir fonte.tmp
	tar xzf fonte.tar.gz -C fonte.tmp --strip-components=1
	echo "== aplicando t2040-kernel.patch"
	(cd fonte.tmp && patch -p1 --no-backup-if-mismatch -s < "$AQUI/t2040-kernel.patch")
	mv fonte.tmp fonte
	rm fonte.tar.gz
fi

if [ ! -x clang-r383902b/bin/clang ]; then
	echo "== baixando o Clang r383902b (Android 11, ~330 MB)"
	curl -fL -o clang.tar.gz "$CLANG_URL"
	mkdir -p clang-r383902b
	tar xzf clang.tar.gz -C clang-r383902b
	rm clang.tar.gz
fi
CL=$TRAB/clang-r383902b/bin
$CL/clang --version | head -1 | grep -q 'r383902b' || { echo "Clang errado: precisa ser o r383902b"; exit 1; }

mkdir -p out
cp "$AQUI/config-t2040" out/.config
M=(make -C fonte O="$TRAB/out" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- LOCALVERSION=
   CC=$CL/clang HOSTCC=gcc CLANG_TRIPLE=arm-linux-gnueabi- LD=$CL/ld.lld TARGET_BUILD_VARIANT=user)
"${M[@]}" olddefconfig > /dev/null
if ! cmp -s out/.config "$AQUI/config-t2040"; then
	echo "AVISO: o olddefconfig mudou a configuracao (diff abaixo). Os modulos do tablet podem nao carregar."
	diff "$AQUI/config-t2040" out/.config || true
fi

echo "== compilando (pode levar de 10 a 40 minutos)"
"${M[@]}" -j"$(nproc)" Image modules

echo "== conferindo a ABI com os modulos originais do tablet"
python3 "$AQUI/conferir-abi.py" "$AQUI/crcs-modulos-vendor.txt" out/Module.symvers

echo
echo "Kernel pronto: $TRAB/out/arch/arm/boot/Image"
echo "Monte o boot.img com:  python3 ../boot/montar-boot.py --base t2040-boot.img --kernel $TRAB/out/arch/arm/boot/Image -o meu-boot.img"
