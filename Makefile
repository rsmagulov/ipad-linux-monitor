# make                  build the host (connector-host)
# make ipa              build the iPad app (needs clang, lld and an iOS SDK, see README)
# make install          install into $(PREFIX) (default /usr/local); then: sudo connector-setup
# make deb              build a .deb for this Debian/Ubuntu/Mint release
PREFIX ?= /usr/local
LIBDIR = $(PREFIX)/lib/connector
BINDIR = $(PREFIX)/bin
SCRIPTS = connector connector-display connector-service autostart ipad-install install.sh

all:
	$(MAKE) -C host

ipa:
	ios/build.sh

install: all
	install -d $(DESTDIR)$(LIBDIR)/host $(DESTDIR)$(LIBDIR)/scripts $(DESTDIR)$(LIBDIR)/ios $(DESTDIR)$(BINDIR)
	install -m755 host/connector-host $(DESTDIR)$(LIBDIR)/host/
	for s in $(SCRIPTS); do install -m755 scripts/$$s $(DESTDIR)$(LIBDIR)/scripts/; done
	install -m644 scripts/connector-config scripts/70-connector.rules $(DESTDIR)$(LIBDIR)/scripts/
	if [ -f ios/Connector.ipa ]; then install -m644 ios/Connector.ipa $(DESTDIR)$(LIBDIR)/ios/; fi
	ln -sf ../lib/connector/scripts/connector $(DESTDIR)$(BINDIR)/connector
	ln -sf ../lib/connector/scripts/connector-display $(DESTDIR)$(BINDIR)/connector-display
	ln -sf ../lib/connector/scripts/autostart $(DESTDIR)$(BINDIR)/connector-autostart
	ln -sf ../lib/connector/scripts/ipad-install $(DESTDIR)$(BINDIR)/connector-ipad-install
	ln -sf ../lib/connector/scripts/install.sh $(DESTDIR)$(BINDIR)/connector-setup

uninstall:
	rm -rf $(DESTDIR)$(LIBDIR)
	rm -f $(addprefix $(DESTDIR)$(BINDIR)/,connector connector-display connector-autostart \
		connector-ipad-install connector-setup)

deb:
	packaging/build-deb.sh

clean:
	$(MAKE) -C host clean
	rm -rf ios/build ios/Connector.ipa

.PHONY: all ipa install uninstall deb clean
