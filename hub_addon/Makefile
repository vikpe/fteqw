all: csaddon.dat

FTEQCC ?= fteqcc
FTEQCCFLAGS ?= -O0

csaddon.dat: $(wildcard src/*.qc) src/progs.src
	$(FTEQCC) $(FTEQCCFLAGS) -src src

clean:
	rm -f csaddon.dat csaddon.lno
