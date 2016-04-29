#!/bin/bash

# Script to configure a Sahana server on Debian Wheezy/Jessie with Apache & MySQL
#
# Execute like:
#     bash configure-sahana-apache-mysql.sh
#
# =============================================================================
# Configuration

WEB2PYDIR=~web2py
EDENDIR=$WEB2PYDIR/applications/eden

if [ ! -d "$EDENDIR" ]; then
    echo "Sahana installation not found - did you run the installation script?"
    exit 1
fi

# Which OS are we running?
read -d . DEBIAN < /etc/debian_version
if [ $DEBIAN == '8' ]; then
    echo "Detected Debian 8"
    DEBIAN_NAME='jessie'
    # Apache 2.4
    extension='.conf'
    GRANT='Require all granted'
else
    echo "Assuming Debian 7"
    DEBIAN_NAME='wheezy'
    # Apache 2.2
    extension=''
    GRANT='    Order deny,allow
    Allow from all'
fi

# =============================================================================
# Read in configuration details
#
echo -e "What domain name should we use? : \c "
read DOMAIN

echo -e "What host name should we use? : \c "
read hostname
sitename=$hostname".$DOMAIN"

echo -e "What is the current root MySQL password: \c "
read -s rootpw
echo

echo "Note that web2py will not work with passwords with an @ in them."
echo -e "What should be the MySQL password for user 'sahana'? \c "
read password

# =============================================================================
echo "Configuring system..."

cd /etc
filename="hosts"
sed -i "s|localdomain localhost|localdomain localhost $hostname|" $filename

cd /etc
filename="hostname"
echo $hostname > $filename

cd /etc
filename="mailname"
echo $sitename >  $filename

# =============================================================================
# Email
#
echo "Configure for Internet mail delivery"
dpkg-reconfigure exim4-config

# =============================================================================
# Update System
#
echo "Updating system..."
apt-get update
apt-get upgrade -y

# =============================================================================
# Update Sahana
#
echo "Updating Sahana..."
cd ~web2py/applications/eden
git pull
rm -rf $EDENDIR/compiled

# =============================================================================
# Apache Web server
#
echo "Setting up Apache web server"

# Create production site
cat << EOF > "/etc/apache2/sites-available/production$extension"
<VirtualHost *:80>
  ServerName $hostname.$DOMAIN
  ServerAdmin webmaster@$DOMAIN
  DocumentRoot /home/web2py/applications 

  WSGIScriptAlias / /home/web2py/wsgihandler.py
  ## Edit the process and the maximum-requests to reflect your RAM 
  WSGIDaemonProcess web2py user=web2py group=web2py home=/home/web2py processes=4 maximum-requests=100

  RewriteEngine On
  # Stop GoogleBot from slowing us down
  RewriteRule .*robots\.txt$ /eden/static/robots.txt [L]
  # extract desired cookie value from multiple-cookie HTTP header
  #RewriteCond %{HTTP_COOKIE} registered=([^;]+)
  # check that cookie value is correct
  #RewriteCond %1 ^yes$
  #RewriteRule ^/$ /eden/ [R,L]
  #RewriteRule ^/$ /eden/static/index.html [R,L]
  RewriteCond %{REQUEST_URI}    !/phpmyadmin(.*)
  RewriteCond %{REQUEST_URI}    !/eden/(.*)
  RewriteRule /(.*) /eden/$1 [R]

  ### static files do not need WSGI
  <LocationMatch "^(/[\w_]*/static/.*)">
    Order Allow,Deny
    Allow from all
    
    SetOutputFilter DEFLATE
    BrowserMatch ^Mozilla/4 gzip-only-text/html
    BrowserMatch ^Mozilla/4\.0[678] no-gzip
    BrowserMatch \bMSIE !no-gzip !gzip-only-text/html
    SetEnvIfNoCase Request_URI \.(?:gif|jpe?g|png)$ no-gzip dont-vary
    Header append Vary User-Agent env=!dont-vary

    ExpiresActive On
    ExpiresByType text/html "access plus 1 day"
    ExpiresByType text/javascript "access plus 1 week"
    ExpiresByType text/css "access plus 2 weeks"
    ExpiresByType image/ico "access plus 1 month"
    ExpiresByType image/gif "access plus 1 month"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/jpg "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType application/x-shockwave-flash "access plus 1 month"
  </LocationMatch>
  ### everything else goes over WSGI
  <Location "/">
    $GRANT
    WSGIProcessGroup web2py
  </Location>

  ErrorLog /var/log/apache2/$hostname_error.log
  LogLevel warn
  CustomLog /var/log/apache2/$hostname_access.log combined
</VirtualHost>
EOF

# Create maintenance site
cat << EOF > "/etc/apache2/sites-available/maintenance$extension"
<VirtualHost *:80>
  ServerName $hostname.$DOMAIN
  ServerAdmin webmaster@$DOMAIN
  DocumentRoot /var/www

  RewriteEngine On
  RewriteCond %{REQUEST_URI} !/phpmyadmin(.*)
  RewriteRule ^/(.*) /maintenance.html

  <Location "/">
    $GRANT
  </Location>

  ErrorLog /var/log/apache2/maintenance_error.log
  LogLevel warn
  CustomLog /var/log/apache2/maintenance_access.log combined
</VirtualHost>
EOF

# Remove default site
rm -f /etc/apache2/sites-enabled/000-default$extension

# Enable production site and restart web server
a2ensite production
apache2ctl restart

# =============================================================================
# MySQL Database
#
echo "Setting up Database"

db="sahana"

# Allow root user to access database without entering password
echo "Creating database..."
cat << EOF > "/root/.my.cnf"
[client]
user=root
EOF
echo "password='$rootpw'" >> "/root/.my.cnf"
# Create database
mysql --user="root" --password="$rootpw" --execute="drop database if exists $db; create database $db;" --verbose

echo "Setting up database user for Sahana application..."
TEMPFILE=/tmp/mypass
cat << EOF > "$TEMPFILE"
GRANT USAGE ON *.* TO 'sahana'@'localhost';
DROP USER 'sahana'@'localhost';
FLUSH PRIVILEGES;
CREATE USER 'sahana'@'localhost' IDENTIFIED BY '$password';
GRANT ALL ON sahana.* TO 'sahana'@'localhost';
EOF
mysql < $TEMPFILE
rm -f $TEMPFILE

# Schedule backups for 02:01 daily
echo "Configuring nightly backup..."
if grep -Fq "/usr/local/bin/backup" /etc/crontab; then
    echo "...backup already configured [SKIP]"
else
    echo "1 2   * * * * root    /usr/local/bin/backup" >> "/etc/crontab"
fi

# =============================================================================
# Sahana
#
echo "Setting up Sahana..."

echo "Copying Config Template..."
rm -rf $EDENDIR/databases/*
rm -rf $EDENDIR/errors/*
rm -rf $EDENDIR/sessions/*
cp $EDENDIR/modules/templates/000_config.py $EDENDIR/models

CONFIG=$EDENDIR/models/000_config.py

echo "Updating Config..."
sed -i 's|EDITING_CONFIG_FILE = False|EDITING_CONFIG_FILE = True|' $CONFIG
sed -i "s|akeytochange|$sitename$password|" $CONFIG
sed -i "s|127.0.0.1:8000|$sitename|" $CONFIG
sed -i 's|base.cdn = False|base.cdn = True|' $CONFIG

echo "Updating database settings..."
sed -i 's|#settings.database.db_type = "mysql"|settings.database.db_type = "mysql"|' $CONFIG
sed -i "s|#settings.database.password = \"password\"|settings.database.password = \"$password\"|" $CONFIG

echo "Creating the tables & populating with base data..."
sed -i 's|settings.base.prepopulate = 0|settings.base.prepopulate = 1|' $CONFIG
sed -i 's|settings.base.migrate = False|settings.base.migrate = True|' $CONFIG
cd $WEB2PYDIR
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py

echo "Compiling for production..."
sed -i 's|settings.base.prepopulate = 1|settings.base.prepopulate = 0|' $CONFIG
sed -i 's|settings.base.migrate = True|settings.base.migrate = False|' $CONFIG
cd $WEB2PYDIR
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py

echo "Setting up scheduler..."
sed -i 's|exit 0|cd ~web2py \&\& python web2py.py -K eden -Q >/dev/null 2>\&1 \&|' /etc/rc.local
echo "exit 0" >> /etc/rc.local

# =============================================================================
# END
#
echo "Done...reboot? [y/n]"
read answer
case $answer in
    y)
        echo "Rebooting..."
        reboot;;
    *)
        echo "Please reboot manually to activate Sahana"
        exit 0;;
esac

# =============================================================================
