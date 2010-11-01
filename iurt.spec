############################################
# Warning
#   This package must be handled 
#   via /svn/soft/build_system/iurt/trunk/
############################################

%define name iurt
%define release %mkrel 1

Name: %{name}
Version: 0.6.4
Release: %{release}
License: GPL
Summary: Packages rebuilder
Group: Development/Tools
URL: http://svn.mandriva.com/cgi-bin/viewvc.cgi/soft/build_system/iurt/trunk/
Source: %{name}.tar
BuildRoot: %{_tmppath}/%{name}-buildroot
Requires: mkcd
BuildArch: noarch

%description
iurt is a collection of tools to create an automatic rebuild system. It contains
the rebuild script, iurt, as well as the scheduler, ulri, and the upload script, 
emi.

%prep
%setup -q -n %{name}-%{version}

%install
rm -rf $RPM_BUILD_ROOT
%makeinstall DESTDIR=$RPM_BUILD_ROOT

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%{_bindir}/emi
%{_bindir}/iurt
%{_bindir}/ulri
%{_sbindir}/iurt_root_command
%{perl_vendorlib}/Iurt

