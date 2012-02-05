
NAME=iurt
PACKAGE=$(NAME)
VERSION=0.6.5

FILES= Makefile emi iurt.spec iurt2 iurt_root_command lib ulri 
RPM=$(HOME)/rpm

VENDORLIB = $(shell eval "`perl -V:installvendorlib`"; echo $$installvendorlib)
INSTALLVENDORLIB = $(DESTDIR)$(VENDORLIB)

SVNSOFT=svn+ssh://svn.mageia.org/svn/soft/build_system/iurt/trunk/
SVNPACKAGE=svn+ssh://svn.mageia.org/svn/packages/cauldron/iurt/current/

sharedir=/usr/share
libdir=/usr/lib
bindir=/usr/bin
sbindir=/usr/sbin

localrpm: localcopy tar 

install:
	install -d $(bindir) $(sbindir) $(INSTALLVENDORLIB)/Iurt
	install -m 644 lib/Iurt/*.pm $(INSTALLVENDORLIB)/Iurt
	install -m755 iurt_root_command $(sbindir)/
	install -m755 iurt2 $(bindir)/iurt
	install -m755 emi ulri $(bindir)/

tar:  
	tar cfa $(PACKAGE)-$(VERSION).tar.xz $(PACKAGE)-$(VERSION)
	rm -rf $(PACKAGE)-$(VERSION)

localcopy:
	rm -fr $(PACKAGE)-$(VERSION)
	svn export -q -rBASE . $(PACKAGE)-$(VERSION)

localrpm: tar $(RPM)
	cp -f $(NAME)-$(VERSION).tar $(RPM)/SOURCES
	-rpm -ba --clean $(NAME).spec
	rm -f $(NAME)-$(VERSION).tar

ci: tar
	svn ci -m 'Update soft SPEC for version $(VERSION)' $(NAME).spec
	# not a good idea
	# svn rm -m 'Remove previously copied spec to replace it for $(VERSION)' $(SVNPACKAGE)/SPECS/$(NAME).spec
	# svn cp -m 'Update package SPEC for version $(VERSION)' $(SVNSOFT)/$(NAME).spec $(SVNPACKAGE)/SPECS/
	mkdir svn; cd svn; mdvsys co $(NAME)
	cp $(NAME).spec svn/$(NAME)/SPECS/
	cp $(NAME)-$(VERSION).tar svn/$(NAME)/SOURCES/
	cd svn/$(NAME)/; mdvsys ci -m 'update tarball and spec for version $(VERSION)' 

rpm: clean ci
	cd svn/$(NAME); bm

clean:
	rm -rf svn

submit: clean ci
	mdvsys submit $(NAME)
