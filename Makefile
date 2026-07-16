UID   := $(shell id -u)
PLIST := $(HOME)/Library/LaunchAgents/local.dimd.plist

dimd: $(wildcard *.swift)
	swiftc -O -o dimd *.swift

install: dimd
	ln -sf $(CURDIR)/dimd $(HOME)/.local/bin/dimd
	sed -e 's|/Users/sour4bh/projects/dimd|$(CURDIR)|g' -e 's|/Users/sour4bh|$(HOME)|g' local.dimd.plist > $(PLIST)
	launchctl bootout gui/$(UID)/local.dimd 2>/dev/null || true
	launchctl bootstrap gui/$(UID) $(PLIST)

reload: install

status:
	./dimd --status
	@launchctl print gui/$(UID)/local.dimd 2>/dev/null | grep -E 'state|pid' || echo "agent: not loaded"

log:
	tail -20 $(HOME)/Library/Logs/dimd.log

uninstall:
	launchctl bootout gui/$(UID)/local.dimd 2>/dev/null || true
	rm -f $(PLIST) $(HOME)/.local/bin/dimd

.PHONY: install reload status log uninstall
