PREFIX  ?= /usr/local
CC      ?= clang
CFLAGS  ?= -O2 -fobjc-arc -Wall -Wno-deprecated-declarations
LDFLAGS ?= -framework Cocoa -framework IOKit -framework CoreFoundation

BIN     := build/monitorctl
BINDEST := $(PREFIX)/bin/monitorctl
LABEL   := com.monitorctl.menubar
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist
UID_NUM := $(shell id -u)

.PHONY: all install uninstall install-agent uninstall-agent restart clean

all: $(BIN)

$(BIN): src/monitorctl.m
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Installs a root-owned binary. Root ownership matters: the app runs this
# path with sudo, so it must not be writable by a normal user.
install: $(BIN)
	install -d -m 755 -o root -g wheel $(PREFIX)/bin
	install -m 755 -o root -g wheel $(BIN) $(BINDEST)

uninstall: uninstall-agent
	rm -f $(BINDEST)

# Start the menu bar app at login (run without sudo, after `sudo make install`).
install-agent:
	@mkdir -p $(HOME)/Library/LaunchAgents
	sed 's|@BINARY@|$(BINDEST)|' launchd/$(LABEL).plist > $(AGENT)
	-launchctl bootout gui/$(UID_NUM)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(UID_NUM) $(AGENT)

uninstall-agent:
	-launchctl bootout gui/$(UID_NUM)/$(LABEL) 2>/dev/null
	rm -f $(AGENT)

# Pick up a freshly installed binary.
restart:
	launchctl kickstart -k gui/$(UID_NUM)/$(LABEL)

clean:
	rm -rf build
