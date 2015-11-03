#!/bin/bash
echo -e '192.168.50.50\txnat.test.net' | sudo tee --append /etc/hosts
XNAT=xnat-1.6.5
JAVA_PATH=/usr/lib/jvm/java-7-openjdk-amd64

# create tomcat7 user
sudo useradd -g users -d /home/tomcat7 -s /bin/bash tomcat7
sudo groupadd tomcat7
sudo usermod -a -G tomcat7 tomcat7
sudo mkdir /home/tomcat7
sudo chown -R tomcat7:tomcat7 /home/tomcat7

# create xnat database user
sudo useradd -g users xnat01

# install dependencies
sudo apt-get update
sudo apt-get upgrade
sudo apt-get -y install postgresql
sudo apt-get -y install openjdk-7-jdk
sudo apt-get -y install tomcat7

# setup keys
sudo apt-get -y install gnutls-bin ssl-cert
sudo sh -c "certtool --generate-privkey > /etc/ssl/private/cakey.pem"
echo -e 'cn = Test Organisation\nca\ncert_signing_key' | sudo tee /etc/ssl/ca.info
sudo certtool --generate-self-signed --load-privkey /etc/ssl/private/cakey.pem --template /etc/ssl/ca.info --outfile /etc/ssl/certs/cacert.pem
sudo certtool --generate-privkey --bits 1024 --outfile /etc/ssl/private/test_slapd_key.pem
echo -e 'organization = Test Organisation\ncn = xnat.test.net\ntls_www_server\nencryption_key\nsigning_key\nexpiration_days = 7' | sudo tee /etc/ssl/test.info
sudo certtool --generate-certificate --load-privkey /etc/ssl/private/test_slapd_key.pem --load-ca-certificate /etc/ssl/certs/cacert.pem --load-ca-privkey /etc/ssl/private/cakey.pem --template /etc/ssl/test.info --outfile /etc/ssl/certs/test_slapd_cert.pem
# tell java about our new certs
sudo keytool -importcert -noprompt -storepass changeit -alias testRootCert -file /etc/ssl/certs/cacert.pem -keystore /usr/lib/jvm/java-7-openjdk-amd64/jre/lib/security/cacerts

# install ldap
sudo debconf-set-selections /vagrant/dpkg.txt
sudo apt-get -y install slapd ldap-utils
sudo adduser openldap ssl-cert
sudo chgrp ssl-cert /etc/ssl/private/test_slapd_key.pem
sudo chmod g+r /etc/ssl/private/test_slapd_key.pem
sudo chmod o-r /etc/ssl/private/test_slapd_key.pem

# boost the ldap logging level
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/logging.ldif
# see https://technicalnotes.wordpress.com/2014/04/19/openldap-setup-with-memberof-overlay/
# add memberof overlay
sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/memberof.ldif
# add referential integrity so that, for instance when you remove a user, associated memberships are removed too
# TODO: remove / consolidate these two lines
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/refint.ldif
sudo ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/refint_config.ldif
# load default ldap users and groups
ldapadd -c -x -H ldap://localhost:389 -D "cn=admin,dc=test,dc=net" -w adminpassword -f /vagrant/users.ldif
# configure tls encryption
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /vagrant/certinfo.ldif
sudo sed -i -e 's/ldap:\/\/\//ldap:\/\/xnat.test.net ldaps:\/\/xnat.test.net/g' /etc/default/slapd
sudo service slapd restart
# update ACLs so that nodes can edit people
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/node-account.ldif
# remove anonymous access
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/removeanon.ldif

# download xnat
cd /opt
if [ -f /vagrant/${XNAT}.tar.gz ]; then
    sudo cp /vagrant/${XNAT}.tar.gz .
else
    sudo curl -O ftp://ftp.nrg.wustl.edu/pub/xnat/${XNAT}.tar.gz
fi
sudo tar -zxvf ${XNAT}.tar.gz
sudo mv xnat ${XNAT}
sudo cp /vagrant/build.properties /opt/${XNAT}
sudo cp /vagrant/services.properties /opt/${XNAT}/plugin-resources/conf/services.properties
sudo cp /vagrant/project.properties /opt/${XNAT}

# database settings
sudo -u postgres createuser -U postgres -S -D -R xnat01
sudo -u postgres psql -U postgres -c "ALTER USER xnat01 WITH PASSWORD 'xnat'"
sudo -u postgres createdb -U postgres -O xnat01 xnat

# create data dir
sudo mkdir /opt/data
sudo chown -R tomcat7:tomcat7 /opt/data

# xnat installation
sudo service tomcat7 stop
sudo chown -R tomcat7:tomcat7 /opt/${XNAT}
sudo chmod -R 777 /opt/${XNAT}
cd /opt/${XNAT}
sudo su tomcat7 -c "echo 'export JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64' >> /home/tomcat7/.bashrc"
sudo su tomcat7 -c "echo 'export PATH=\${PATH}:/opt/${XNAT}/bin' >> /home/tomcat7/.bashrc"
# all setup, now build
sudo su tomcat7 -c "source ~/.bashrc && bin/setup.sh -Ddeploy=true"
cd deployments/xnat
sudo -u xnat01 psql -d xnat -f sql/xnat.sql -U xnat01
sudo su tomcat7 -c "source ~/.bashrc && StoreXML -l security/security.xml -allowDataDeletion true"
sudo su tomcat7 -c "source ~/.bashrc && StoreXML -dir ./work/field_groups -u admin -p admin -allowDataDeletion true"
sudo service tomcat7 start
