#!/bin/bash
#
# Script to configure a Sahana server on Debian Wheezy/Jessie with Apache & MySQL
#
# License: MIT
#
# Execute like:
#     bash cherokee-postgis-configure.sh
#
# =============================================================================
# Configuration

WEB2PYDIR=~web2py
EDENDIR=$WEB2PYDIR/applications/eden

if [ ! -d "$EDENDIR" ]; then
    echo "Sahana installation not found - did you run the installation script?"
    exit 1
fi

# =============================================================================
# Read in configuration details
#
echo -e "What domain name should we use? : \c "
read DOMAIN

echo -e "What host name should we use? : \c "
read hostname
sitename=$hostname".$DOMAIN"

echo -e "Which template should we use? [Enter=default] : \c "
read template

# @ToDo: Generate a random password
echo "Note that web2py will not work with passwords with an @ in them."
echo -e "What should be the PostgreSQL password for user 'sahana'? \c "
read password

---

# =============================================================================
echo "Configuring system..."

cd /etc
filename="hosts"
sed -i "s|localdomain localhost|localdomain localhost $hostname|" $filename
sed -i "s|localhost.localdomain localhost|$sitename $hostname localhost.localdomain localhost|" $filename

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
# Configure PostgreSQL
echo "Configuring PostgreSQL user 'sahana'"
echo "CREATE USER sahana WITH PASSWORD '$password';" > /tmp/pgpass.sql
su -c - postgres "psql -q -d template1 -f /tmp/pgpass.sql"
rm -f /tmp/pgpass.sql
su -c - postgres "createdb -O sahana -E UTF8 sahana -T template0"
#su -c - postgres "createlang plpgsql -d sahana"

# =============================================================================
# PostGIS
echo "Configuring PostGIS"
#su -c - postgres "psql -q -d sahana -f /usr/share/postgresql/9.4/extension/postgis--2.2.1.sql"
su -c - postgres "psql -q -d sahana -c 'CREATE EXTENSION postgis;'"
su -c - postgres "psql -q -d sahana -c 'grant all on geometry_columns to sahana;'"
su -c - postgres "psql -q -d sahana -c 'grant all on spatial_ref_sys to sahana;'"

# =============================================================================
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
if [ ! -z "$template" ]; then
    sed -i "s|settings.base.template = \"default\"|settings.base.template = \"$template\"|" $CONFIG
fi

sed -i 's|EDITING_CONFIG_FILE = False|EDITING_CONFIG_FILE = True|' $CONFIG
sed -i "s|#settings.base.public_url = \"http://127.0.0.1:8000\"|settings.base.public_url = \"http://$sitename\"|" $CONFIG
sed -i 's|#settings.base.cdn = True|settings.base.cdn = True|' $CONFIG

# Create a unique HMAC key for password encryption
UUID=`python -c $'import uuid\nprint uuid.uuid4()'`
sed -i "s|akeytochange|$UUID|" $CONFIG

echo "Updating database settings..."
sed -i 's|#settings.database.db_type = "postgres"|settings.database.db_type = "postgres"|' $CONFIG
sed -i "s|#settings.database.password = \"password\"|settings.database.password = \"$password\"|" $CONFIG
sed -i 's|#settings.gis.spatialdb = True|settings.gis.spatialdb = True|' $CONFIG

echo "Creating the tables & populating with base data..."
# sed -i 's|settings.base.prepopulate = 0|settings.base.prepopulate = 1|' $CONFIG
sed -i 's|settings.base.migrate = False|settings.base.migrate = True|' $CONFIG
cd $WEB2PYDIR
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py

echo "Compiling for production..."
sed -i 's|#settings.base.prepopulate = 0|settings.base.prepopulate = 0|' $CONFIG
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
