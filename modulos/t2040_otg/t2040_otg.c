// SPDX-License-Identifier: GPL-2.0
/* T2040: liga a deteccao do OTG (pino USB_ID) no kernel proprio.
 * O extcon-usb-gpio.c da arvore Realme so pede a IRQ do ID quando alguem chama otg_switch_mode(1) (o
 * "interruptor de OTG" do ColorOS, via POWER_SUPPLY_PROP_OTG_SWITCHER do charger-manager da Realme). O
 * charger-manager do nosso kernel nao tem isso, entao o OTG nunca era detectado. O kernel original da
 * Positivo pede a IRQ do ID no probe. otg_switch_mode nao e exportada: achada por kallsyms_lookup_name. */
#include <linux/kallsyms.h>
#include <linux/module.h>

static void (*otg_switch)(int);

static int __init t2040_otg_init(void)
{
	otg_switch = (void (*)(int))kallsyms_lookup_name("otg_switch_mode");
	if (!otg_switch) {
		pr_err("t2040-otg: otg_switch_mode nao encontrada\n");
		return -ENOENT;
	}
	otg_switch(1);
	pr_info("t2040-otg: deteccao do OTG ligada\n");
	return 0;
}

static void __exit t2040_otg_exit(void)
{
	otg_switch(0);
}

module_init(t2040_otg_init);
module_exit(t2040_otg_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("T2040: liga a deteccao do OTG (USB_ID) do extcon-usb-gpio da Realme");
