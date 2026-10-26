# Uses system dev packages if present, otherwise the local sysroot in ../.deps
DEPS    ?= $(abspath ../.deps/sysroot)
CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter
VERSION ?= $(shell cat ../VERSION 2>/dev/null || echo dev)
CPPFLAGS += -DCONNECTOR_VERSION='"$(VERSION)"'
CPPFLAGS += $(if $(wildcard $(DEPS)),-I$(DEPS)/usr/include -I$(DEPS)/usr/include/x86_64-linux-gnu)
LDFLAGS  += $(if $(wildcard $(DEPS)),-L$(DEPS)/usr/lib/x86_64-linux-gnu)
# libusbmuxd 2.0.1 (Ubuntu 20.04) is still called libusbmuxd
USBMUXD ?= $(shell pkg-config --libs libusbmuxd-2.0 2>/dev/null || pkg-config --libs libusbmuxd 2>/dev/null || echo -lusbmuxd-2.0)
LDLIBS   = -lX11 -lXext -lXfixes -lXrandr -lXtst -lavcodec -lavutil -lswscale $(USBMUXD) -lssl -lcrypto -l:libxkbcommon.so.0

connector-host: connector-host.c protocol.h ../VERSION
	$(CC) $(CPPFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS) $(LDLIBS)

clean:
	rm -f connector-host

.PHONY: clean
