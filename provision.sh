#!/bin/bash
echo -e '192.168.50.50\txnat.test.net' | sudo tee --append /etc/hosts
XNAT=xnat-1.6.4
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
#sudo keytool -importcert -noprompt -storepass changeit -alias ldapCert -file /etc/ssl/certs/test_slapd_cert.pem -keystore /usr/lib/jvm/java-7-openjdk-amd64/jre/lib/security/cacerts

# install ldap
sudo debconf-set-selections /vagrant/dpkg.txt
sudo apt-get -y install slapd ldap-utils
sudo adduser openldap ssl-cert
sudo chgrp ssl-cert /etc/ssl/private/test_slapd_key.pem
sudo chmod g+r /etc/ssl/private/test_slapd_key.pem
sudo chmod o-r /etc/ssl/private/test_slapd_key.pem

# load default ldap user
ldapadd -c -x -H ldap://localhost:389 -D "cn=admin,dc=test,dc=net" -w adminpassword -f /vagrant/users.ldif
# boost the ldap logging level
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/logging.ldif
# configure tls encryption
sudo ldapmodify -Y EXTERNAL -H ldapi:/// -f /vagrant/certinfo.ldif
sudo sed -i -e 's/ldap:\/\/\//ldap:\/\/xnat.test.net/g' /etc/default/slapd
sudo service slapd restart
# remove anonymous access
sudo ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /vagrant/removeanon.ldif

# extract prophylactic .maven repository
# see https://groups.google.com/forum/#!topic/xnat_discussion/O14Y0G2ENmc
# todo: remove at xnat 1.6.5
cd /home/tomcat7
if [ -f /vagrant/xnat-maven.zip ]; then
    sudo cp /vagrant/xnat-maven.zip .
else
    sudo curl -O ftp://ftp.nrg.wustl.edu/pub/xnat/xnat-maven.zip
fi
sudo apt-get install -y unzip
sudo chown tomcat7:tomcat7 /home/tomcat7/xnat-maven.zip
sudo su tomcat7 -c "unzip xnat-maven.zip"
sudo su tomcat7 -c "find ~/.maven -exec touch {} \;"

# download xnat
cd /opt
if [ -f /vagrant/xnat-1.6.4.tar.gz ]; then
    sudo cp /vagrant/xnat-1.6.4.tar.gz .
else
    sudo curl -O ftp://ftp.nrg.wustl.edu/pub/xnat/${XNAT}.tar.gz
fi
sudo tar -zxvf ${XNAT}.tar.gz
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
sudo chown -R tomcat7:tomcat7 /vagrant/build.properties
sudo chown -R tomcat7:tomcat7 /opt/${XNAT}
sudo chmod -R 777 /opt/${XNAT}
cd /opt/${XNAT}
sudo su tomcat7 -c "echo 'export JAVA_HOME=/usr/lib/jvm/java-7-openjdk-amd64' >> /home/tomcat7/.bashrc"
sudo su tomcat7 -c "echo 'export PATH=\${PATH}:/opt/${XNAT}/bin' >> /home/tomcat7/.bashrc"
# note next line more maven hyginx, see above
sudo su tomcat7 -c "cp -R ~/.maven/repository/javax.persistence /opt/${XNAT}/plugin-resources/repository/."
# patch xnat for startTls compatibility
sudo su tomcat7 -c "sed -i -e 's/import java.util.Arrays;/import org.springframework.ldap.core.support.DefaultTlsDirContextAuthenticationStrategy;\nimport java.util.Arrays;/g' plugin-resources/webapp/xnat/java/org/nrg/xnat/security/config/LdapAuthenticationProviderConfigurator.java"
sudo su tomcat7 -c "sed -i -e 's/afterPropertiesSet();/if (properties.get(\"useStartTls\").equals(\"true\")) setAuthenticationStrategy(new DefaultTlsDirContextAuthenticationStrategy());\n            afterPropertiesSet();/g' plugin-resources/webapp/xnat/java/org/nrg/xnat/security/config/LdapAuthenticationProviderConfigurator.java"
# all setup, now build
sudo su tomcat7 -c "source ~/.bashrc && bin/setup.sh -Ddeploy=true"
cd deployments/xnat
sudo -u xnat01 psql -d xnat -f sql/xnat.sql -U xnat01
sudo su tomcat7 -c "source ~/.bashrc && StoreXML -l security/security.xml -allowDataDeletion true"
sudo su tomcat7 -c "source ~/.bashrc && StoreXML -dir ./work/field_groups -u admin -p admin -allowDataDeletion true"
sudo service tomcat7 start
