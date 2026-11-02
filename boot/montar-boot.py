#!/usr/bin/env python3
"""Monta o boot.img do Positivo T2040 com um kernel e/ou /init novos e reassina o AVB.

A particao boot e verificada pelo AVB com a chave de referencia publica da Unisoc
(rsa4096_boot.pem), que a Positivo nunca trocou. Este script reaproveita o layout
AVB de uma imagem base ja assinada (o t2040-boot.img da release), recalcula o hash
e assina de novo. Antes, confere que reassinar a base sem mudancas reproduz a base
byte a byte (prova de que a chave e o layout estao certos).

Uso:
  python montar-boot.py --base t2040-boot.img --kernel Image -o meu-boot.img
  python montar-boot.py --base t2040-boot.img --init init -o meu-boot.img

Saidas: meu-boot.img (64 MiB) e meu-boot.sparse.img (para o fastboot).
Requer: pip install cryptography
"""
import argparse, gzip, hashlib, pathlib, struct, urllib.request

CHAVE_URL = ('https://raw.githubusercontent.com/TomKing062/vendor_sprd_proprietories-source_packimage/'
             '88046980c972751acfbd787291cf3cc4e8ea02ed/sign_image/config-unisoc/rsa4096_boot.pem')
CHAVE_SHA256 = 'd7352aa740a6d73dd9a454db98ed9b018580bfc2940cc7f38512b2918abae97c'
PAGE = 2048


def pad(b, n=PAGE):
    return b + bytes(-len(b) % n)


# ---------- boot.img header v2 ----------
def ler_boot(img):
    u = lambda o: struct.unpack_from('<I', img, o)[0]
    assert img[:8] == b'ANDROID!' and u(36) == PAGE and u(40) == 2, 'base nao e boot.img v2 com pagina de 2048'
    assert u(24) == 0 and u(1632) == 0, 'base com second/recovery_dtbo, nao suportado'
    ks, rs, ds = u(8), u(16), u(1648)
    o = PAGE
    kernel = img[o:o + ks]; o += len(pad(kernel))
    ramdisk = img[o:o + rs]; o += len(pad(ramdisk))
    dtb = img[o:o + ds]
    return bytearray(img[:PAGE]), kernel, ramdisk, dtb


def montar_boot(hdr, kernel, ramdisk, dtb):
    hdr = bytearray(hdr)
    struct.pack_into('<I', hdr, 8, len(kernel))
    struct.pack_into('<I', hdr, 16, len(ramdisk))
    struct.pack_into('<I', hdr, 1648, len(dtb))
    h = hashlib.sha1()
    for blob in (kernel, ramdisk, b'', b'', dtb):
        h.update(blob); h.update(struct.pack('<I', len(blob)))
    hdr[576:608] = h.digest() + bytes(12)
    return bytes(hdr) + pad(kernel) + pad(ramdisk) + pad(dtb)


# ---------- initramfs (cpio newc dentro de gzip) ----------
def cpio_ler(data):
    ents, o = [], 0
    while True:
        assert data[o:o + 6] == b'070701', 'initramfs nao e cpio newc'
        f = [int(data[o + 6 + 8 * i:o + 14 + 8 * i], 16) for i in range(13)]
        nsz, fsz = f[11], f[6]
        nome = data[o + 110:o + 110 + nsz - 1].decode()
        o += 110 + nsz; o += -o % 4
        corpo = data[o:o + fsz]; o += fsz; o += -o % 4
        ents.append([f, nome, corpo])
        if nome == 'TRAILER!!!':
            return ents


def cpio_gravar(ents):
    out = bytearray()
    for f, nome, corpo in ents:
        f = list(f); f[6] = len(corpo); f[11] = len(nome) + 1
        out += b'070701' + b''.join(b'%08X' % (x & 0xffffffff) for x in f) + nome.encode() + b'\0'
        out += bytes(-len(out) % 4) + corpo
        out += bytes(-len(out) % 4)
    return bytes(out + bytes(-len(out) % 512))


def trocar_init(ramdisk_gz, init):
    ents = cpio_ler(gzip.decompress(ramdisk_gz))
    alvo = [e for e in ents if e[1] == 'init']
    assert len(alvo) == 1, 'initramfs sem /init'
    alvo[0][2] = init.replace(b'\r\n', b'\n')
    return gzip.compress(cpio_gravar(ents), 9, mtime=0)


# ---------- AVB (footer + vbmeta embutido, SHA256_RSA4096) ----------
class Avb:
    def __init__(self, base):
        assert base[-64:-60] == b'AVBf', 'base sem footer AVB'
        self.orig_size, self.vb_off, _ = struct.unpack_from('>QQQ', base, len(base) - 64 + 12)
        p = self.vb_off
        assert base[p:p + 4] == b'AVB0'
        (self.auth_sz, self.aux_sz, alg, self.hash_off, self.hash_sz, self.sig_off, self.sig_sz,
         self.pk_off, self.pk_sz) = struct.unpack_from('>QQIQQQQQQ', base, p + 12)
        self.desc_off, self.desc_sz = struct.unpack_from('>QQ', base, p + 12 + 68 + 16)
        assert alg == 2, 'algoritmo AVB diferente de SHA256_RSA4096'
        self.aux = p + 256 + self.auth_sz
        self.base_len = len(base)
        self.pk_n = int.from_bytes(base[self.aux + self.pk_off + 8:self.aux + self.pk_off + 520], 'big')
        # descritor de hash da particao boot
        o, fim = self.aux + self.desc_off, self.aux + self.desc_off + self.desc_sz
        self.hd = None
        while o < fim:
            tag, n = struct.unpack_from('>QQ', base, o)
            if tag == 2:
                img_sz, = struct.unpack_from('>Q', base, o + 16)
                alg_h = base[o + 24:o + 56].rstrip(b'\0').decode()
                nlen, slen, dlen = struct.unpack_from('>III', base, o + 56)
                q = o + 16 + 116
                nome = base[q:q + nlen].decode()
                assert nome == 'boot' and alg_h == 'sha256' and img_sz == self.orig_size
                self.salt = base[q + nlen:q + nlen + slen]
                self.digest_pos, self.dlen = q + nlen + slen, dlen
                self.hd = True
            o += 16 + n
        assert self.hd, 'descritor de hash do boot nao encontrado'

    def assinar(self, img, chave):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding
        img = bytearray(img)
        dig = hashlib.sha256(self.salt + img[:self.orig_size]).digest()
        img[self.digest_pos:self.digest_pos + self.dlen] = dig
        p = self.vb_off
        msg = bytes(img[p:p + 256] + img[self.aux:self.aux + self.aux_sz])
        sig = chave.sign(msg, padding.PKCS1v15(), hashes.SHA256())
        a = p + 256
        img[a + self.hash_off:a + self.hash_off + self.hash_sz] = hashlib.sha256(msg).digest()
        img[a + self.sig_off:a + self.sig_off + self.sig_sz] = sig
        return bytes(img)


def obter_chave(caminho):
    from cryptography.hazmat.primitives import serialization
    if caminho:
        d = pathlib.Path(caminho).read_bytes()
    else:
        print('baixando a chave de referencia da Unisoc:', CHAVE_URL)
        d = urllib.request.urlopen(CHAVE_URL, timeout=60).read()
        assert hashlib.sha256(d).hexdigest() == CHAVE_SHA256, 'rsa4096_boot.pem baixado com conteudo inesperado'
    return serialization.load_pem_private_key(d, None)


# ---------- sparse do fastboot: RAW nos blocos com dado, DONT_CARE nos zerados ----------
def sparse(img, bs=4096):
    assert len(img) % bs == 0
    n = len(img) // bs
    chunks, i = [], 0
    vazio = bytes(bs)
    while i < n:
        z = img[i * bs:(i + 1) * bs] == vazio
        j = i + 1
        while j < n and (img[j * bs:(j + 1) * bs] == vazio) == z:
            j += 1
        if z:
            chunks.append(struct.pack('<HHII', 0xCAC3, 0, j - i, 12))
        else:
            chunks.append(struct.pack('<HHII', 0xCAC1, 0, j - i, 12 + (j - i) * bs) + img[i * bs:j * bs])
        i = j
    return struct.pack('<IHHHHIIII', 0xED26FF3A, 1, 0, 28, 12, bs, n, len(chunks), 0) + b''.join(chunks)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--base', required=True, help='boot.img assinado de referencia (t2040-boot.img da release)')
    ap.add_argument('--kernel', help='Image do kernel (arch/arm/boot/Image)')
    ap.add_argument('--init', help='novo /init para o initramfs')
    ap.add_argument('--initramfs', help='initramfs completo (.cpio.gz) no lugar do da base')
    ap.add_argument('--chave', help='rsa4096_boot.pem local (se omitido, baixa do GitHub e confere o SHA-256)')
    ap.add_argument('-o', '--saida', required=True)
    a = ap.parse_args()

    base = pathlib.Path(a.base).read_bytes()
    avb = Avb(base)
    chave = obter_chave(a.chave)
    assert chave.public_key().public_numbers().n == avb.pk_n, 'a chave nao corresponde a chave publica da base'
    assert avb.assinar(base, chave) == base, 'reassinar a base sem mudancas nao reproduziu a base: PARE'

    hdr, kernel, ramdisk, dtb = ler_boot(base)
    if a.kernel:
        kernel = pathlib.Path(a.kernel).read_bytes()
        assert kernel[:4] != b'\x7fELF', 'use o arch/arm/boot/Image, nao o vmlinux'
    if a.initramfs:
        ramdisk = pathlib.Path(a.initramfs).read_bytes()
    elif a.init:
        ramdisk = trocar_init(ramdisk, pathlib.Path(a.init).read_bytes())

    boot = montar_boot(hdr, kernel, ramdisk, dtb)
    assert len(boot) <= avb.orig_size, 'imagem maior que o limite do AVB (%d > %d)' % (len(boot), avb.orig_size)
    img = bytearray(base)
    img[:avb.orig_size] = boot + bytes(avb.orig_size - len(boot))
    img = avb.assinar(img, chave)

    out = pathlib.Path(a.saida)
    out.write_bytes(img)
    sp = out.with_name(out.stem + '.sparse.img')
    sp.write_bytes(sparse(img))
    print('%s  %s' % (hashlib.sha256(img).hexdigest(), out))
    print('%s  %s' % (hashlib.sha256(sp.read_bytes()).hexdigest(), sp))
    print('kernel %d bytes, initramfs %d bytes, dtb %d bytes, usado %d de %d' %
          (len(kernel), len(ramdisk), len(dtb), len(boot), avb.orig_size))


if __name__ == '__main__':
    main()
