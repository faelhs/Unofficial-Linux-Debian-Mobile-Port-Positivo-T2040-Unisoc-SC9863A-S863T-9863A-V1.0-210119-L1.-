#!/usr/bin/env python3
"""Confere se o kernel compilado exporta os simbolos com os mesmos CRCs que os modulos
.ko originais do tablet exigem (secao __versions). Sem isso, eles recusam carregar.

Uso: python3 conferir-abi.py crcs-modulos-vendor.txt out/Module.symvers
Sai com codigo 1 se algum simbolo faltar ou tiver CRC diferente.
"""
import collections, sys

exigido = collections.defaultdict(dict)  # simbolo -> {modulo: crc}
for linha in open(sys.argv[1]):
    mod, sym, crc = linha.split()
    exigido[sym][mod] = int(crc, 16)

tem = {}
for linha in open(sys.argv[2]):
    p = linha.rstrip('\n').split('\t')
    if len(p) >= 2:
        tem[p[1]] = int(p[0], 16)

ruins = []
for sym, mods in sorted(exigido.items()):
    crc = next(iter(mods.values()))
    if sym not in tem:
        ruins.append('AUSENTE %s (usado por %s)' % (sym, ','.join(sorted(mods))))
    elif tem[sym] != crc:
        ruins.append('CRC %s original=0x%08x compilado=0x%08x (usado por %s)' % (sym, crc, tem[sym], ','.join(sorted(mods))))

print('simbolos exigidos pelos modulos do tablet: %d, iguais: %d' % (len(exigido), len(exigido) - len(ruins)))
for r in ruins:
    print(r)
sys.exit(1 if ruins else 0)
