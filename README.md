vagrant-xnat-ldap
============

Provision Ubuntu 14.04 based Vagrant box with XNAT 1.6.4 linked to a local openldap directory.

### Dependencies:
* VirtualBox
* Vagrant

### Installation:
```bash
git clone git@github.com:mattsouth/vagrant-xnat-ldap.git
cd vagrant-xnat-ldap
vagrant up
```

Once the Vagrant box is up and running XNAT is available at http://192.168.50.50:8080/xnat

To read or write to the directory you will need to logon with the User DN 'dc=admin,dc=test,dc=net' and password 'adminpassword'

### Change IP address of Vagrant box:
* Change xdat.url option in build.properties
* Change config.vm.network option in Vagrantfile
