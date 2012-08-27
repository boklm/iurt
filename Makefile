
NAME=iurt
PACKAGE=$(NAME)
VERSION=0.6.7

VENDORLIB = $(shell eval "`perl -V:installvendorlib`"; echo $$installvendorlib)
INSTALLVENDORLIB = $(DESTDIR)$(VENDORLIB)

SVNSOFT=svn+ssh://svn.mageia.org/svn/soft/build_system/iurt/trunk/
SVNPACKAGE=svn+ssh://svn.mageia.org/svn/packages/cauldron/iurt/current/

sharedir=/usr/share
libdir=/usr/lib
bindir=/usr/bin
sbindir=/usr/sbin

install:
	install -d $(bindir) $(sbindir) $(INSTALLVENDORLIB)/Iurt
	install -m 644 lib/Iurt/*.pm $(INSTALLVENDORLIB)/Iurt
	install -m755 iurt_root_command $(sbindir)/
	install -m755 iurt $(bindir)/iurt
	install -m755 emi ulri $(bindir)/

tar: dist

dist:
	rm -rf ../$(NAME)-$(VERSION).tar*
	@if svn info > /dev/null; then \
		$(MAKE) dist-svn; \
	elif [ -e ".git" ]; then \
		$(MAKE) dist-git; \
	else \
		echo "Unknown SCM (not SVN nor GIT)";\
		exit 1; \
	fi;
	$(info $(NAME)-$(VERSION).tar.xz is ready)

dist-svn:
	svn export -q -rBASE . $(PACKAGE)-$(VERSION)
	tar cfa $(PACKAGE)-$(VERSION).tar.xz $(PACKAGE)-$(VERSION)
	rm -rf $(PACKAGE)-$(VERSION)

dist-git:
	git archive --prefix $(NAME)-$(VERSION)/ HEAD | xz -9 > ../$(NAME)-$(VERSION).tar.xz

clean:
	rm -rf svn

submit: clean ci
	mdvsys submit $(NAME)
