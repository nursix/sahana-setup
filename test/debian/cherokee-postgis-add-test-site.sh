#!/bin/bash
#
# Script to add a test instance to a Sahana server configured with Cherokee/PostgreSQL
#
# License: MIT
#
# Execute like:
#     bash cherokee-postgis-add-test-site.sh

# Stable 2.14.6
WEB2PY_COMMIT=cda35fd

INSTANCE=test
INSTANCE_HOME=/home/$INSTANCE

# =============================================================================
# Read configuration parameters
#
echo -e "What FQDN will be used to access the $INSTANCE site? : \c "
read sitename
if [ -z "sitename" ]; then
    echo "Error: FQDN is required!"
    exit 1
fi

echo -e "Start the $INSTANCE site at boot? : y|[n] \c "
read autostart

# =============================================================================
# Create symbolic links for primary instance
#
if [ -d "/home/web2py" ]; then
    if [ ! -e "/home/prod" ]; then
        ln -sf /home/web2py /home/prod
        ln -sf /home/prod ~
    fi
else
    echo "Error: no production instance installed?"
    exit 1
fi
PROD=/home/prod

# =============================================================================
# Install web2py
#
echo "Cloning web2py"

cd /home
if [ -d "$INSTANCE/applications" ]; then
    echo "WARNING: This will remove the existing web2py/Sahana installation"
    echo "Type 'yes' if you are certain"
    read answer
    case $answer in
        yes)
            echo "Removing existing installation..."
            rm -rf $INSTANCE;;
        *)
            echo "Aborting..."
            exit 1;;
    esac
fi
git clone --recursive git://github.com/web2py/web2py.git $INSTANCE
ln -sf /home/$INSTANCE ~

# Use a specific commit?
if [ ! -z "$WEB2PY_COMMIT" ]; then
    echo "Checking out web2py stable"
    cd $INSTANCE
    git reset --hard $WEB2PY_COMMIT
    git submodule update
    cd ..
fi

echo "Copying WSGI Handler"
cp -f $INSTANCE_HOME/handlers/wsgihandler.py $INSTANCE_HOME

echo "Setting up routes"
cat << EOF > "$INSTANCE_HOME/routes.py"
#!/usr/bin/python
default_application = 'eden'
default_controller = 'default'
default_function = 'index'
routes_onerror = [
        ('eden/400', '!'),
        ('eden/401', '!'),
        ('eden/509', '!'),
        ('eden/*', '/eden/errors/index'),
        ('*/*', '/eden/errors/index'),
    ]
EOF

# Configure Matplotlib
mkdir $INSTANCE_HOME/.matplotlib
chown web2py $INSTANCE_HOME/.matplotlib
echo "os.environ['MPLCONFIGDIR'] = '$INSTANCE_HOME/.matplotlib'" >> /home/web2py/wsgihandler.py
sed -i 's|TkAgg|Agg|' /etc/matplotlibrc

# =============================================================================
# Sahana
#
APPLICATIONS=$INSTANCE_HOME/applications
EDEN=$APPLICATIONS/eden

cd $APPLICATIONS

echo "Cloning Sahana"
git clone git://github.com/sahana/eden.git

echo "Fixing permissions"
declare -a admindirs=("cache" "cron" "databases" "errors" "sessions" "uploads")
chown web2py $INSTANCE_HOME
for i in "${admindirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p $APPLICATIONS/admin/$i
    fi
    chown -v web2py $APPLICATIONS/admin/$i
done

declare -a edendirs=("cache" "cron" "databases" "models" "errors" "sessions" "uploads")
chown web2py $EDEN
for i in "${edendirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p $EDEN/$i
    fi
    chown -v web2py $EDEN/$i
done

# Additional upload directories
mkdir -p $EDEN/uploads/gis_cache
mkdir -p $EDEN/uploads/images
mkdir -p $EDEN/uploads/tracks
chown web2py $EDEN/uploads/gis_cache
chown web2py $EDEN/uploads/images
chown web2py $EDEN/uploads/tracks

# Additional static directories
mkdir -p $EDEN/static/cache/chart
chown web2py $EDEN/static/fonts
chown web2py $EDEN/static/img/markers
chown web2py -R $EDEN/static/cache

# Create symbolic links
ln -fs $APPLICATIONS/eden ~
ln -fs $APPLICATIONS/eden $INSTANCE_HOME/eden

# =============================================================================
# Configure Sahana
#
echo "Configuring Sahana"

CONFIG=$EDEN/models/000_config.py

cp $PROD/applications/eden/models/000_config.py $CONFIG
sed -i "s|settings.base.public_url = .*\"|settings.base.public_url = \"http://$sitename\"|" $CONFIG
sed -i "s|settings.mail.sender = .*\"|#settings.mail.sender = disabled|" $CONFIG
sed -i "s|#settings.database.database = \"sahana\"|settings.database.database = \"sahana-$INSTANCE\"|" $CONFIG

# =============================================================================
# Scheduler config
#
echo "Adding scheduler config"

cat << EOF > "$INSTANCE_HOME/run_scheduler.py"
#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os
import sys

if '__file__' in globals():
    path = os.path.dirname(os.path.abspath(__file__))
    os.chdir(path)
else:
    path = os.getcwd() # Seems necessary for py2exe

sys.path = [path]+[p for p in sys.path if not p==path]

# import gluon.import_all ##### This should be uncommented for py2exe.py
import gluon.widget
from gluon.shell import run

# Start Web2py Scheduler -- Note the app name is hardcoded!
if __name__ == '__main__':
    run('eden',True,True,None,False,"from gluon import current; current._scheduler.loop()")
EOF

# =============================================================================
# Configure uWSGI
#
echo "Configuring uWSGI"

# uWSGI config
cat << EOF > "$INSTANCE_HOME/uwsgi.ini"
[uwsgi]
uid = web2py
gid = web2py
chdir = /home/$INSTANCE/
module = wsgihandler
mule = run_scheduler.py
workers = 4
cheap = true
idle = 1000
harakiri = 1000
pidfile = /tmp/uwsgi-$INSTANCE.pid
daemonize = /var/log/uwsgi/$INSTANCE.log
socket = 127.0.0.1:59026
master = true
EOF

# PID file path
touch /tmp/uwsgi-$INSTANCE.pid
chown web2py: /tmp/uwsgi-$INSTANCE.pid

# =============================================================================
# Init script for uwsgi
#
echo "Creating uWSGI init script"

cat << EOF > "/etc/init.d/uwsgi-$INSTANCE"
#! /bin/bash
# /etc/init.d/uwsgi-$INSTANCE
#
daemon=/usr/local/bin/uwsgi
pid=/tmp/uwsgi-$INSTANCE.pid
args="/home/$INSTANCE/uwsgi.ini"

# Carry out specific functions when asked to by the system
case "\$1" in
    start)
        echo "Starting uwsgi"
        start-stop-daemon -p \$pid --start --exec \$daemon -- \$args
        ;;
    stop)
        echo "Stopping script uwsgi"
        start-stop-daemon --signal INT -p \$pid --stop \$daemon -- \$args
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    reload)
        echo "Reloading conf"
        kill -HUP \`cat \$pid\`
        ;;
    *)
        echo "Usage: /etc/init.d/uwsgi-$INSTANCE {start|stop|restart|reload}"
        exit 1
    ;;
esac
exit 0
EOF
chmod a+x /etc/init.d/uwsgi-$INSTANCE

if [ '$autostart' = 'y' ]; then
    echo "Configuring $INSTANCE instance for start at boot"
    update-rc.d uwsgi-$INSTANCE defaults
fi

echo "Starting uWSGI"
/etc/init.d/uwsgi-$INSTANCE start

# =============================================================================
# Cherokee vserver
#
echo "Adding vserver configuration for Cherokee"

cat << EOF > "/tmp/update_cherokee.py"
vserver = """vserver!40!collector!enabled = 1
vserver!40!directory_index = index.html
vserver!40!document_root = /var/www
vserver!40!error_handler = error_redir
vserver!40!error_handler!503!show = 0
vserver!40!error_handler!503!url = /maintenance.html
vserver!40!error_writer!filename = /var/log/cherokee/cherokee.error
vserver!40!error_writer!type = file
vserver!40!logger = combined
vserver!40!logger!access!buffsize = 16384
vserver!40!logger!access!filename = /var/log/cherokee/cherokee.access
vserver!40!logger!access!type = file
vserver!40!match = wildcard
vserver!40!match!domain!1 = $sitename
vserver!40!match!nick = 0
vserver!40!nick = Test
vserver!40!rule!700!expiration = epoch
vserver!40!rule!700!expiration!caching = public
vserver!40!rule!700!expiration!caching!must-revalidate = 1
vserver!40!rule!700!expiration!caching!no-store = 0
vserver!40!rule!700!expiration!caching!no-transform = 0
vserver!40!rule!700!expiration!caching!proxy-revalidate = 1
vserver!40!rule!700!handler = common
vserver!40!rule!700!handler!allow_dirlist = 0
vserver!40!rule!700!handler!allow_pathinfo = 0
vserver!40!rule!700!match = fullpath
vserver!40!rule!700!match!fullpath!1 = /maintenance.html
vserver!40!rule!500!document_root = $EDEN/static
vserver!40!rule!500!encoder!deflate = allow
vserver!40!rule!500!encoder!gzip = allow
vserver!40!rule!500!expiration = time
vserver!40!rule!500!expiration!time = 7d
vserver!40!rule!500!handler = file
vserver!40!rule!500!match = fullpath
vserver!40!rule!500!match!fullpath!1 = /favicon.ico
vserver!40!rule!500!match!fullpath!2 = /robots.txt
vserver!40!rule!500!match!fullpath!3 = /crossdomain.xml
vserver!40!rule!400!document_root = $EDEN/static/img
vserver!40!rule!400!encoder!deflate = forbid
vserver!40!rule!400!encoder!gzip = forbid
vserver!40!rule!400!expiration = time
vserver!40!rule!400!expiration!caching = public
vserver!40!rule!400!expiration!caching!must-revalidate = 0
vserver!40!rule!400!expiration!caching!no-store = 0
vserver!40!rule!400!expiration!caching!no-transform = 0
vserver!40!rule!400!expiration!caching!proxy-revalidate = 0
vserver!40!rule!400!expiration!time = 7d
vserver!40!rule!400!handler = file
vserver!40!rule!400!match = directory
vserver!40!rule!400!match!directory = /eden/static/img/
vserver!40!rule!400!match!final = 1
vserver!40!rule!300!document_root = $EDEN/static
vserver!40!rule!300!encoder!deflate = allow
vserver!40!rule!300!encoder!gzip = allow
vserver!40!rule!300!expiration = epoch
vserver!40!rule!300!expiration!caching = public
vserver!40!rule!300!expiration!caching!must-revalidate = 1
vserver!40!rule!300!expiration!caching!no-store = 0
vserver!40!rule!300!expiration!caching!no-transform = 0
vserver!40!rule!300!expiration!caching!proxy-revalidate = 1
vserver!40!rule!300!handler = file
vserver!40!rule!300!match = directory
vserver!40!rule!300!match!directory = /eden/static/
vserver!40!rule!300!match!final = 1
vserver!40!rule!200!encoder!deflate = allow
vserver!40!rule!200!encoder!gzip = allow
vserver!40!rule!200!handler = uwsgi
vserver!40!rule!200!handler!balancer = round_robin
vserver!40!rule!200!handler!balancer!source!10 = 2
vserver!40!rule!200!handler!check_file = 0
vserver!40!rule!200!handler!error_handler = 1
vserver!40!rule!200!handler!modifier1 = 0
vserver!40!rule!200!handler!modifier2 = 0
vserver!40!rule!200!handler!pass_req_headers = 1
vserver!40!rule!200!match = directory
vserver!40!rule!200!match!directory = /
vserver!40!rule!100!handler = common
vserver!40!rule!100!handler!iocache = 1
vserver!40!rule!100!match = default
"""

source = """source!2!env_inherited = 1
source!2!group = web2py
source!2!host = 127.0.0.1:59026
source!2!interpreter = /usr/local/bin/uwsgi -s 127.0.0.1:59026 -x $INSTANCE_HOME/uwsgi.xml
source!2!nick = uWSGI 2
source!2!timeout = 1000
source!2!type = host
source!2!user = web2py
"""

File = open("/etc/cherokee/cherokee.conf", "r")
file = File.readlines()
File.close()
File = open("/etc/cherokee/cherokee.conf", "w")
for line in file:
    if "source!1!env_inherited" in line:
        File.write(vserver)
    elif "icons!directory" in line:
        File.write(source)
    File.write(line)
File.close()
EOF
python /tmp/update_cherokee.py

# =============================================================================
# Management scripts
#
echo "Updating management scripts"

# -----------------------------------------------------------------------------
echo "...compile"
cat << EOF > "/usr/local/bin/compile"
#!/bin/bash
set -e
if [[ -z "\$1" ]]; then
    echo >&2 "Instance needs to be specified: prod or $INSTANCE"
    exit 1
elif [[ ! -d "/home/\$1" ]]; then
    echo >&2 "\$1 is not a valid instance!"
    exit 1
fi
INSTANCE=\$1
cd /home/\$INSTANCE
/etc/init.d/uwsgi-\$INSTANCE stop
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-\$INSTANCE start
EOF
chmod +x /usr/local/bin/compile

# -----------------------------------------------------------------------------
echo "...pull"
cat << EOF > "/usr/local/bin/pull"
#!/bin/bash
set -e
if [[ -z "\$1" ]]; then
    echo >&2 "Instance needs to be specified: prod or $INSTANCE"
    exit 1
elif [[ ! -d "/home/\$1" ]]; then
    echo >&2 "\$1 is not a valid instance!"
    exit 1
fi
INSTANCE=\$1
/etc/init.d/uwsgi-\$INSTANCE stop
cd /home/\$INSTANCE/applications/eden
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
git reset --hard HEAD
git pull
rm -rf compiled
cd /home/\$INSTANCE
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd /home/\$INSTANCE/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
cd /home/\$INSTANCE
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-\$INSTANCE start
EOF
chmod +x /usr/local/bin/pull

# -----------------------------------------------------------------------------
echo "...clean"
cat << EOF > "/usr/local/bin/clean"
#!/bin/bash
set -e
if [ -z "\$1" ]; then
    echo >&2 "Instance needs to be specified: prod or $INSTANCE"
    exit 1
elif [ ! -d "/home/\$1" ]; then
    echo >&2 "\$1 is not a valid instance!"
    exit 1
fi

INSTANCE=\$1
if [ "\$1" = "prod" ]; then
    echo "You selected: Production"
    echo -n "Are you absolutely sure? (yes/n):"
    read confirm
    if [ "\$confirm" != "yes" ]; then
        echo "Cancelled"; exit
    fi
    DATABASE="sahana"
else
    DATABASE="sahana-\$INSTANCE"
fi

echo >&2 "Cleaning instance: \$INSTANCE"
/etc/init.d/uwsgi-\$INSTANCE stop
cd /home/\$INSTANCE/applications/eden
rm -rf databases/*
rm -f errors/*
rm -rf sessions/*
rm -rf uploads/*
echo >&2 "Dropping database: \$DATABASE"
set +e
pkill -f "postgres: sahana \$DATABASE"
sudo -H -u postgres dropdb \$DATABASE
set -e
echo >&2 "Creating database: \$DATABASE"
su -c - postgres "createdb -O sahana -E UTF8 \$DATABASE -T template0"

if [ "\$1" = "$INSTANCE" ]; then
    echo >&2 "Refreshing database from Production: \$DATABASE"
    su -c - postgres "pg_dump -c sahana > /tmp/sahana.sql"
    su -c - postgres "psql -f /tmp/sahana.sql \$DATABASE"
    if [ -e "$PROD/applications/eden/uploads/*" ]; then
        cp -pr $PROD/applications/eden/uploads/* /home/\$INSTANCE/applications/eden/uploads/
    fi
    cp -pr /home/prod/applications/eden/databases/* /home/\$INSTANCE/applications/eden/databases/
    cd /home/\$INSTANCE/applications/eden/databases
    for i in *.table; do mv "\$i" "\${i/PROD_TABLE_STRING/TEST_TABLE_STRING}"; done
else
    echo >&2 "Migrating/Populating database: \$DATABASE"
    #su -c - postgres "createlang plpgsql -d \$DATABASE"
    #su -c - postgres "psql -q -d \$DATABASE -f /usr/share/postgresql/9.4/extension/postgis--2.2.2.sql"
    su -c - postgres "psql -q -d \$DATABASE -c 'CREATE EXTENSION postgis;'"
    su -c - postgres "psql -q -d \$DATABASE -c 'grant all on geometry_columns to sahana;'"
    su -c - postgres "psql -q -d \$DATABASE -c 'grant all on spatial_ref_sys to sahana;'"
    echo >&2 "Starting DB actions with eden"
    cd /home/\$INSTANCE/applications/eden
    sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
    sed -i "s/settings.base.prepopulate = 0/#settings.base.prepopulate = 0/g" models/000_config.py
    rm -rf compiled
    cd /home/\$INSTANCE
    sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
    cd /home/\$INSTANCE/applications/eden
    sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
    sed -i "s/#settings.base.prepopulate = 0/settings.base.prepopulate = 0/g" models/000_config.py
fi

echo >&2 "Compiling..."
cd /home/\$INSTANCE
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-\$INSTANCE start

# Post-pop
#if [ "\$1" = "$INSTANCE"]; then
#    echo >&2 "pass"
#else
#    cd /home/\$INSTANCE
#    sudo -H -u web2py python web2py.py -S eden -M -R /home/data/import.py
#fi
EOF
chmod +x /usr/local/bin/clean

# -----------------------------------------------------------------------------
cat << EOF > "/tmp/update_clean.py"
import hashlib
(db_string, pool_size) = settings.get_database_string()
prod_table_string = hashlib.md5(db_string).hexdigest()
settings.database.database = "sahana-$INSTANCE"
(db_string, pool_size) = settings.get_database_string()
test_table_string = hashlib.md5(db_string).hexdigest()
File = open("/usr/local/bin/clean", "r")
file = File.readlines()
File.close()
File = open("/usr/local/bin/clean", "w")
for line in file:
    if "TABLE_STRING" in line:
        line = line.replace("PROD_TABLE_STRING", prod_table_string).replace("TEST_TABLE_STRING", test_table_string)
    File.write(line)
File.close()
EOF
cd /home/web2py
python web2py.py -S eden -M -R /tmp/update_clean.py

# -----------------------------------------------------------------------------
echo "...w2p"
cat << EOF > "/usr/local/bin/w2p"
#!/bin/bash
set -e
if [[ -z "\$1" ]]; then
    echo >&2 "Instance needs to be specified: prod or $INSTANCE"
    exit 1
elif [[ ! -d "/home/\$1" ]]; then
    echo >&2 "\$1 is not a valid instance!"
    exit 1
fi
INSTANCE=\$1
cd /home/\$INSTANCE
python web2py.py -S eden -M
EOF
chmod +x /usr/local/bin/w2p

# =============================================================================
# 1st time setup
clean $INSTANCE

echo "Restarting Cherokee"
/etc/init.d/cherokee restart

# =============================================================================
# END
echo "Test instance installation successful"

# =============================================================================
