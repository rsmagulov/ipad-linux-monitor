# Uses system dev packages if present, otherwise the local sysroot in ../.deps
DEPS    ?= $(abspath ../.deps/sysroot)
CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
VERSION ?= $(shell cat ../VERSION 2>/dev/null || echo dev)
CPPFLAGS += -DCONNECTOR_VERSION='"$(VERSION)"'
CPPFLAGS += $(if $(wildcard $(DEPS)),-I$(DEPS)/usr/include -I$(DEPS)/usr/include/x86_64-linux-gnu)
LDFLAGS  += $(if $(wildcard $(DEPS)),-L$(DEPS)/usr/lib/x86_64-linux-gnu)
LDLIBS   = -lX11 -lXext -lXfixes -lXrandr -lXtst -lavcodec -lavutil -lswscale -lusbmuxd-2.0 -lssl -lcrypto -l:libxkbcommon.so.0

connector-host: connector-host.c protocol.h ../VERSION
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

clean:
	rm -f connector-host

.PHONY: clean
