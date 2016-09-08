#!/bin/bash
#
# Script to add a demo instance to a Sahana server configured with Cherokee/PostgreSQL
#
# License: MIT
#
# Execute like:
#     bash cherokee-postgis-add-test-site.sh

# Stable 2.14.6
WEB2PY_COMMIT=cda35fd

INSTANCE=demo
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
socket = 127.0.0.1:59027
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
vserver = """vserver!50!collector!enabled = 1
vserver!50!directory_index = index.html
vserver!50!document_root = /var/www
vserver!50!error_handler = error_redir
vserver!50!error_handler!503!show = 0
vserver!50!error_handler!503!url = /maintenance.html
vserver!50!error_writer!filename = /var/log/cherokee/cherokee.error
vserver!50!error_writer!type = file
vserver!50!logger = combined
vserver!50!logger!access!buffsize = 16384
vserver!50!logger!access!filename = /var/log/cherokee/cherokee.access
vserver!50!logger!access!type = file
vserver!50!match = wildcard
vserver!50!match!domain!1 = $sitename
vserver!50!match!nick = 0
vserver!50!nick = Demo
vserver!50!rule!700!expiration = epoch
vserver!50!rule!700!expiration!caching = public
vserver!50!rule!700!expiration!caching!must-revalidate = 1
vserver!50!rule!700!expiration!caching!no-store = 0
vserver!50!rule!700!expiration!caching!no-transform = 0
vserver!50!rule!700!expiration!caching!proxy-revalidate = 1
vserver!50!rule!700!handler = common
vserver!50!rule!700!handler!allow_dirlist = 0
vserver!50!rule!700!handler!allow_pathinfo = 0
vserver!50!rule!700!match = fullpath
vserver!50!rule!700!match!fullpath!1 = /maintenance.html
vserver!50!rule!500!document_root = $EDEN/static
vserver!50!rule!500!encoder!deflate = allow
vserver!50!rule!500!encoder!gzip = allow
vserver!50!rule!500!expiration = time
vserver!50!rule!500!expiration!time = 7d
vserver!50!rule!500!handler = file
vserver!50!rule!500!match = fullpath
vserver!50!rule!500!match!fullpath!1 = /favicon.ico
vserver!50!rule!500!match!fullpath!2 = /robots.txt
vserver!50!rule!500!match!fullpath!3 = /crossdomain.xml
vserver!50!rule!400!document_root = $EDEN/static/img
vserver!50!rule!400!encoder!deflate = forbid
vserver!50!rule!400!encoder!gzip = forbid
vserver!50!rule!400!expiration = time
vserver!50!rule!400!expiration!caching = public
vserver!50!rule!400!expiration!caching!must-revalidate = 0
vserver!50!rule!400!expiration!caching!no-store = 0
vserver!50!rule!400!expiration!caching!no-transform = 0
vserver!50!rule!400!expiration!caching!proxy-revalidate = 0
vserver!50!rule!400!expiration!time = 7d
vserver!50!rule!400!handler = file
vserver!50!rule!400!match = directory
vserver!50!rule!400!match!directory = /eden/static/img/
vserver!50!rule!400!match!final = 1
vserver!50!rule!300!document_root = $EDEN/static
vserver!50!rule!300!encoder!deflate = allow
vserver!50!rule!300!encoder!gzip = allow
vserver!50!rule!300!expiration = epoch
vserver!50!rule!300!expiration!caching = public
vserver!50!rule!300!expiration!caching!must-revalidate = 1
vserver!50!rule!300!expiration!caching!no-store = 0
vserver!50!rule!300!expiration!caching!no-transform = 0
vserver!50!rule!300!expiration!caching!proxy-revalidate = 1
vserver!50!rule!300!handler = file
vserver!50!rule!300!match = directory
vserver!50!rule!300!match!directory = /eden/static/
vserver!50!rule!300!match!final = 1
vserver!50!rule!200!encoder!deflate = allow
vserver!50!rule!200!encoder!gzip = allow
vserver!50!rule!200!handler = uwsgi
vserver!50!rule!200!handler!balancer = round_robin
vserver!50!rule!200!handler!balancer!source!10 = 3
vserver!50!rule!200!handler!check_file = 0
vserver!50!rule!200!handler!error_handler = 1
vserver!50!rule!200!handler!modifier1 = 0
vserver!50!rule!200!handler!modifier2 = 0
vserver!50!rule!200!handler!pass_req_headers = 1
vserver!50!rule!200!match = directory
vserver!50!rule!200!match!directory = /
vserver!50!rule!100!handler = common
vserver!50!rule!100!handler!iocache = 1
vserver!50!rule!100!match = default
"""

source = """source!3!env_inherited = 1
source!3!group = web2py
source!3!host = 127.0.0.1:59027
source!3!interpreter = /usr/local/bin/uwsgi -s 127.0.0.1:59027 -x $INSTANCE_HOME/uwsgi.xml
source!3!nick = uWSGI 3
source!3!timeout = 1000
source!3!type = host
source!3!user = web2py
"""

File = open("/etc/cherokee/cherokee.conf", "r")
file = File.readlines()
File.close()
File = open("/etc/cherokee/cherokee.conf", "w")
for line in file:
    if "source!2!env_inherited" in line:
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

sed -i "s|prod or test|prod, demo or test|" /usr/local/bin/clean
sed -i "s|prod or test|prod, demo or test|" /usr/local/bin/compile
sed -i "s|prod or test|prod, demo or test|" /usr/local/bin/pull
sed -i "s|prod or test|prod, demo or test|" /usr/local/bin/w2p

# =============================================================================
# 1st time setup
clean $INSTANCE

echo "Restarting Cherokee"
/etc/init.d/cherokee restart

# =============================================================================
# END
echo "Demo instance installation successful"

# =============================================================================
