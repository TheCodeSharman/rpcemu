#
# HostCmd gateway module - assembled with GNU ARM binutils.
# (build.sh overrides AS/LD/OBJCOPY with the arm-linux-gnueabi- toolchain.)
#

AS = armas
LD = armld
OBJCOPY = armobjcopy


all: hostcmd,ffa

%,ffa: %.elf
	$(OBJCOPY) -O binary $< $@

%.elf: %.o
	$(LD) --section-start .text=0 -o $@ $<

%.o: %.s
	$(AS) -o $@ $<

clean:
	rm -f *.o *.elf *,ffa
