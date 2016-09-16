#!/bin/bash
#
# Script to install Sahana on a Debian Wheezy or Jessie box with Cherokee & PostgreSQL
#
# License: MIT
#
# Execute like:
#     bash cherokee-postgis-install.sh
#
# =============================================================================
# Configuration

# Stable 2.14.6
WEB2PY_COMMIT=cda35fd

# Which OS are we running?
read -d . DEBIAN < /etc/debian_version
if [ $DEBIAN == '8' ]; then
    echo "Detected Debian 8"
    DEBIAN_NAME='jessie'
else
    echo "Assuming Debian 7"
    DEBIAN_NAME='wheezy'
fi

# =============================================================================
# Update system
echo "Updating System"
apt-get update
apt-get upgrade -y
apt-get clean

# =============================================================================
# Install Admin Tools
echo "Installing Admin Tools"
apt-get install -y unzip psmisc mlocate telnet lrzsz vim elinks-lite rcconf htop sudo p7zip dos2unix curl
apt-get clean

# =============================================================================
# Install Git
echo "Installing Git"
apt-get install -y git-core
apt-get clean

# =============================================================================
# Email
echo "Installing Mail Server"
apt-get install -y exim4-config exim4-daemon-light
apt-get clean

# =============================================================================
# Python
#
echo "Installing Python Libraries"
apt-get -y install libgeos-c1
apt-get -y install libgeos-dev

apt-get -y install python-dev
apt-get -y install python-lxml python-setuptools python-dateutil
apt-get -y install python-serial
if [ $DEBIAN == '7' ]; then
    apt-get -y install python-imaging
else
    apt-get -y install python-imaging python-reportlab
fi
apt-get -y install python-imaging
apt-get -y install python-matplotlib
apt-get -y install python-requests
apt-get -y install python-xlwt
apt-get -y install build-essential
apt-get clean

if [ $DEBIAN == '7' ]; then
    # Need ReportLab>3.0 for percentage support (Wheezy installs only 2.5)
    echo "Upgrading ReportLab"
    pip install reportlab
fi

# Install latest Shapely for Simplify enhancements
# Shapely>=1.3 requires GEOS>=3.3.0 (Wheezy=3.3.3, Jessie=3.4.2)
echo "Installing Shapely"
pip install shapely

# Install latest XLRD for XLS import support
echo "Installing XLRD"
pip install xlrd

# =============================================================================
# Web2Py
apt-get -y install libodbc1

# Create user and group web2py
echo "Creating web2py user and group"
if id "web2py" >/dev/null 2>&1; then
    echo "web2py user exists"
else
    adduser --system --disabled-password web2py
fi
if grep -q "web2py" /etc/group; then
    echo "web2py group exits"
else
    addgroup web2py
fi

echo "Cloning web2py"
cd /home
if [ -d "web2py/applications" ]; then
    echo "WARNING: This will remove the existing web2py/Sahana installation"
    echo "Type 'yes' if you are certain"
    read answer
    case $answer in
        yes)
            echo "Removing existing installation..."
            rm -rf web2py;;
        *)
            echo "Aborting..."
            exit 1;;
    esac
fi

git clone --recursive git://github.com/web2py/web2py.git

if [ ! -z "$WEB2PY_COMMIT" ]; then
    echo "Checking out web2py stable"
    cd web2py
    git reset --hard $WEB2PY_COMMIT
    git submodule update
    cd ..
fi

# Create symbolic link
ln -fs /home/web2py ~

echo "Copying WSGI Handler"
cp -f /home/web2py/handlers/wsgihandler.py /home/web2py

echo "Setting up routes"
cat << EOF > "/home/web2py/routes.py"
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
mkdir /home/web2py/.matplotlib
chown web2py /home/web2py/.matplotlib
echo "os.environ['MPLCONFIGDIR'] = '/home/web2py/.matplotlib'" >> /home/web2py/wsgihandler.py
sed -i 's|TkAgg|Agg|' /etc/matplotlibrc

# =============================================================================
# Sahana
cd web2py
cd applications

echo "Cloning Sahana"
git clone git://github.com/sahana/eden.git

echo "Fixing permissions"
declare -a admindirs=("cache" "cron" "databases" "errors" "sessions" "uploads")
chown web2py ~web2py
for i in "${admindirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p ~web2py/applications/admin/$i
    fi
    chown -v web2py ~web2py/applications/admin/$i
done

declare -a edendirs=("cache" "cron" "databases" "models" "errors" "sessions" "uploads")
chown web2py ~web2py/applications/eden
for i in "${edendirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p ~web2py/applications/eden/$i
    fi
    chown -v web2py ~web2py/applications/eden/$i
done

# Additional upload directories
mkdir -p ~web2py/applications/eden/uploads/gis_cache
mkdir -p ~web2py/applications/eden/uploads/images
mkdir -p ~web2py/applications/eden/uploads/tracks
chown web2py ~web2py/applications/eden/uploads/gis_cache
chown web2py ~web2py/applications/eden/uploads/images
chown web2py ~web2py/applications/eden/uploads/tracks

# Additional static directories
mkdir -p ~web2py/applications/eden/static/cache/chart
chown web2py ~web2py/applications/eden/static/fonts
chown web2py ~web2py/applications/eden/static/img/markers
chown web2py -R ~web2py/applications/eden/static/cache

# Create symbolic links
ln -fs /home/web2py/applications/eden ~
ln -fs /home/web2py/applications/eden /home/web2py/eden

# =============================================================================
# Cherokee
echo "Installing Cherokee"
apt-get install -y autoconf automake libtool gettext rrdtool
cd /tmp
wget https://github.com/cherokee/webserver/archive/master.zip
unzip master.zip
cd webserver-master
if [ $DEBIAN == '8' ]; then
    apt-get install -y libtool-bin
fi
sh ./autogen.sh --prefix=/usr --localstatedir=/var --sysconfdir=/etc
make
make install

# Paths for logs and graphs
echo "Creating paths for Cherokee"
mkdir -p /var/log/cherokee
chown www-data:www-data /var/log/cherokee
mkdir -p /var/lib/cherokee/graphs
chown www-data:www-data -R /var/lib/cherokee

# Cherokee start script
echo "Creating start script for Cherokee (etc/init.d/cherokee)"
cat << EOF > "/etc/init.d/cherokee"
#! /bin/sh
#
# start/stop Cherokee web server

### BEGIN INIT INFO
# Provides:          cherokee
# Required-Start:    \$remote_fs \$network \$syslog
# Required-Stop:     \$remote_fs \$network \$syslog
# Should-Start:      \$named
# Should-Stop:       \$named
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start the Cherokee Web server
# Description:       Start the Cherokee Web server
### END INIT INFO

PATH=/sbin:/bin:/usr/sbin:/usr/bin
DAEMON=/usr/sbin/cherokee
NAME=cherokee
PIDFILE=/var/run/cherokee.pid

. /lib/lsb/init-functions

set -e

test -x \$DAEMON || exit 0

case "\$1" in
  start)
        echo "Starting \$NAME web server "
        start-stop-daemon --start --oknodo --pidfile \$PIDFILE --exec \$DAEMON -b
        ;;

  stop)
        echo "Stopping \$NAME web server "
        start-stop-daemon --stop --oknodo --pidfile \$PIDFILE --exec \$DAEMON
        rm -f \$PIDFILE
        ;;

  restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;

  reload|force-reload)
        echo "Reloading web server "
        if [ -f \$PIDFILE ]
            then
            PID=\$(cat \$PIDFILE)
            if ps p \$PID | grep \$NAME >/dev/null 2>&1
            then
                kill -HUP \$PID
            else
                echo "PID present, but \$NAME not found at PID \$PID - Cannot reload"
                exit 1
            fi
        else
            echo "No PID file present for \$NAME - Cannot reload"
            exit 1
        fi
        ;;

  status)
        # Strictly, LSB mandates us to return indicating the different statuses,
        # but that's not exactly Debian compatible - For further information:
        # http://www.freestandards.org/spec/refspecs/LSB_1.3.0/gLSB/gLSB/iniscrptact.html
        # http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=208010
        # ...So we just inform to the invoker and return success.
        echo "\$NAME web server status"
        if [ -e \$PIDFILE ] ; then
            PROCNAME=\$(ps -p \$(cat \$PIDFILE) -o comm=)
            if [ "x\$PROCNAME" = "x" ]; then
                echo "Not running, but PID file present"
            else
                if [ "\$PROCNAME" = "\$NAME" ]; then
                    echo "Running"
                else
                    echo "PID file points to process '\$PROCNAME', not '\$NAME'"
                fi
            fi
        else
            if PID=\$(pidofproc \$DAEMON); then
                echo "Running (PID \$PID), but PIDFILE not present"
            else
                echo "Not running\t"
            fi
        fi
        ;;

  *)
        N=/etc/init.d/\$NAME
        echo "Usage: \$N {start|stop|restart|reload|force-reload|status}" >&2
        exit 1
        ;;
esac

exit 0
EOF
chmod +x /etc/init.d/cherokee

# On-boot configuration (run level)
echo "Adding cherokee to current run level"
update-rc.d cherokee defaults

CHEROKEE_CONF="/etc/cherokee/cherokee.conf"

# =============================================================================
# uWSGI
echo "Installing uWSGI"
cd /tmp
wget http://projects.unbit.it/downloads/uwsgi-1.9.18.2.tar.gz
tar zxvf uwsgi-1.9.18.2.tar.gz
cd uwsgi-1.9.18.2
python uwsgiconfig.py --build pyonly.ini
cp uwsgi /usr/local/bin

# Configure uwsgi
echo "Configuring uWSGI"
# Log rotation
cat << EOF > "/etc/logrotate.d/uwsgi"
/var/log/uwsgi/*.log {
       weekly
       rotate 10
       copytruncate
       delaycompress
       compress
       notifempty
       missingok
}
EOF

# Add Scheduler config
cat << EOF > "/home/web2py/run_scheduler.py"
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

# uWSGI config
cat << EOF > "/home/web2py/uwsgi.ini"
[uwsgi]
uid = web2py
gid = web2py
chdir = /home/web2py/
module = wsgihandler
mule = run_scheduler.py
workers = 4
cheap = true
idle = 1000
harakiri = 1000
pidfile = /tmp/uwsgi-prod.pid
daemonize = /var/log/uwsgi/prod.log
socket = 127.0.0.1:59025
master = true
EOF

# PID path for uWSGI
touch /tmp/uwsgi-prod.pid
chown web2py: /tmp/uwsgi-prod.pid

# Log file path for uWSGI
mkdir -p /var/log/uwsgi
chown web2py: /var/log/uwsgi

# Init script for uwsgi
cat << EOF > "/etc/init.d/uwsgi-prod"
#! /bin/bash
# /etc/init.d/uwsgi-prod
#

daemon=/usr/local/bin/uwsgi
pid=/tmp/uwsgi-prod.pid
args="/home/web2py/uwsgi.ini"

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
        echo "Usage: /etc/init.d/uwsgi {start|stop|restart|reload}"
        exit 1
    ;;
esac
exit 0
EOF

chmod a+x /etc/init.d/uwsgi-prod
update-rc.d uwsgi-prod defaults

# =============================================================================
# Configure Cherokee
# If using an Alternate Theme then can add a rule for that: static/themes/<theme>/img
echo "Configuring Cherokee"
mv "$CHEROKEE_CONF" /tmp
cat << EOF > "$CHEROKEE_CONF"
config!version = 001002002
server!bind!1!port = 80
server!collector = rrd
server!fdlimit = 10240
server!group = www-data
server!ipv6 = 0
server!keepalive = 1
server!keepalive_max_requests = 500
server!panic_action = /usr/share/cherokee/cherokee-panic
server!pid_file = /var/run/cherokee.pid
server!server_tokens = product
server!timeout = 1000
server!user = www-data
vserver!10!collector!enabled = 1
vserver!10!directory_index = index.html
vserver!10!document_root = /var/www
vserver!10!error_writer!filename = /var/log/cherokee/cherokee.error
vserver!10!error_writer!type = file
vserver!10!logger = combined
vserver!10!logger!access!buffsize = 16384
vserver!10!logger!access!filename = /var/log/cherokee/cherokee.access
vserver!10!logger!access!type = file
vserver!10!nick = default
vserver!10!rule!10!handler = common
vserver!10!rule!10!handler!iocache = 1
vserver!10!rule!10!match = default
vserver!20!collector!enabled = 1
vserver!20!directory_index = index.html
vserver!20!document_root = /var/www
vserver!20!error_writer!filename = /var/log/cherokee/cherokee.error
vserver!20!error_writer!type = file
vserver!20!logger = combined
vserver!20!logger!access!buffsize = 16384
vserver!20!logger!access!filename = /var/log/cherokee/cherokee.access
vserver!20!logger!access!type = file
vserver!20!match = wildcard
vserver!20!match!domain!1 = *
vserver!20!match!nick = 0
vserver!20!nick = maintenance
vserver!20!rule!210!handler = file
vserver!20!rule!210!match = fullpath
vserver!20!rule!210!match!fullpath!1 = /maintenance.html
vserver!20!rule!110!handler = redir
vserver!20!rule!110!handler!rewrite!10!regex = ^/*
vserver!20!rule!110!handler!rewrite!10!show = 1
vserver!20!rule!110!handler!rewrite!10!substring = /maintenance.html
vserver!20!rule!110!match = directory
vserver!20!rule!110!match!directory = /
vserver!20!rule!10!handler = common
vserver!20!rule!10!handler!iocache = 1
vserver!20!rule!10!match = default
vserver!30!collector!enabled = 1
vserver!30!directory_index = index.html
vserver!30!document_root = /var/www
vserver!30!error_handler = error_redir
vserver!30!error_handler!503!show = 0
vserver!30!error_handler!503!url = /maintenance.html
vserver!30!error_writer!filename = /var/log/cherokee/cherokee.error
vserver!30!error_writer!type = file
vserver!30!logger = combined
vserver!30!logger!access!buffsize = 16384
vserver!30!logger!access!filename = /var/log/cherokee/cherokee.access
vserver!30!logger!access!type = file
vserver!30!match = wildcard
vserver!30!match!domain!1 = *
vserver!30!match!nick = 0
vserver!30!nick = Production
vserver!30!rule!700!expiration = epoch
vserver!30!rule!700!expiration!caching = public
vserver!30!rule!700!expiration!caching!must-revalidate = 1
vserver!30!rule!700!expiration!caching!no-store = 0
vserver!30!rule!700!expiration!caching!no-transform = 0
vserver!30!rule!700!expiration!caching!proxy-revalidate = 1
vserver!30!rule!700!handler = common
vserver!30!rule!700!handler!allow_dirlist = 0
vserver!30!rule!700!handler!allow_pathinfo = 0
vserver!30!rule!700!match = fullpath
vserver!30!rule!700!match!fullpath!1 = /maintenance.html
vserver!30!rule!500!document_root = /home/web2py/applications/eden/static
vserver!30!rule!500!encoder!deflate = allow
vserver!30!rule!500!encoder!gzip = allow
vserver!30!rule!500!expiration = time
vserver!30!rule!500!expiration!time = 7d
vserver!30!rule!500!handler = file
vserver!30!rule!500!match = fullpath
vserver!30!rule!500!match!fullpath!1 = /favicon.ico
vserver!30!rule!500!match!fullpath!2 = /robots.txt
vserver!30!rule!500!match!fullpath!3 = /crossdomain.xml
vserver!30!rule!400!document_root = /home/web2py/applications/eden/static/img
vserver!30!rule!400!encoder!deflate = forbid
vserver!30!rule!400!encoder!gzip = forbid
vserver!30!rule!400!expiration = time
vserver!30!rule!400!expiration!caching = public
vserver!30!rule!400!expiration!caching!must-revalidate = 0
vserver!30!rule!400!expiration!caching!no-store = 0
vserver!30!rule!400!expiration!caching!no-transform = 0
vserver!30!rule!400!expiration!caching!proxy-revalidate = 0
vserver!30!rule!400!expiration!time = 7d
vserver!30!rule!400!handler = file
vserver!30!rule!400!match = directory
vserver!30!rule!400!match!directory = /eden/static/img/
vserver!30!rule!400!match!final = 1
vserver!30!rule!300!document_root = /home/web2py/applications/eden/static
vserver!30!rule!300!encoder!deflate = allow
vserver!30!rule!300!encoder!gzip = allow
vserver!30!rule!300!expiration = epoch
vserver!30!rule!300!expiration!caching = public
vserver!30!rule!300!expiration!caching!must-revalidate = 1
vserver!30!rule!300!expiration!caching!no-store = 0
vserver!30!rule!300!expiration!caching!no-transform = 0
vserver!30!rule!300!expiration!caching!proxy-revalidate = 1
vserver!30!rule!300!handler = file
vserver!30!rule!300!match = directory
vserver!30!rule!300!match!directory = /eden/static/
vserver!30!rule!300!match!final = 1
vserver!30!rule!200!encoder!deflate = allow
vserver!30!rule!200!encoder!gzip = allow
vserver!30!rule!200!handler = uwsgi
vserver!30!rule!200!handler!balancer = round_robin
vserver!30!rule!200!handler!balancer!source!10 = 1
vserver!30!rule!200!handler!check_file = 0
vserver!30!rule!200!handler!error_handler = 1
vserver!30!rule!200!handler!modifier1 = 0
vserver!30!rule!200!handler!modifier2 = 0
vserver!30!rule!200!handler!pass_req_headers = 1
vserver!30!rule!200!match = directory
vserver!30!rule!200!match!directory = /
vserver!30!rule!100!handler = common
vserver!30!rule!100!handler!iocache = 1
vserver!30!rule!100!match = default
source!1!env_inherited = 1
source!1!group = web2py
source!1!host = 127.0.0.1:59025
source!1!interpreter = /usr/local/bin/uwsgi -s 127.0.0.1:59025 -x /home/web2py/uwsgi.xml
source!1!nick = uWSGI 1
source!1!timeout = 1000
source!1!type = host
source!1!user = web2py
EOF

grep 'icons!' /tmp/cherokee.conf >> "$CHEROKEE_CONF"
grep 'mime!' /tmp/cherokee.conf >> "$CHEROKEE_CONF"

cat << EOF >> "$CHEROKEE_CONF"
admin!ows!enabled = 0
EOF

# For a static home page, push 400->500 & 300->400 & insert this
#vserver!30!rule!300!document_root = /home/web2py/applications/eden/static
#vserver!30!rule!300!handler = redir
#vserver!30!rule!300!handler!rewrite!10!regex = ^.*$
#vserver!30!rule!300!handler!rewrite!10!show = 1
#vserver!30!rule!300!handler!rewrite!10!substring = /eden/static/index.html
#vserver!30!rule!300!match = and
#vserver!30!rule!300!match!final = 1
#vserver!30!rule!300!match!left = fullpath
#vserver!30!rule!300!match!left!fullpath!1 = /
#vserver!30!rule!300!match!right = not
#vserver!30!rule!300!match!right!right = header
#vserver!30!rule!300!match!right!right!complete = 0
#vserver!30!rule!300!match!right!right!header = Cookie
#vserver!30!rule!300!match!right!right!match = re
#vserver!30!rule!300!match!right!right!type = regex

# Holding Page for Maintenance windows
echo "Creating maintenance page"
cat << EOF > "/var/www/maintenance.html"
<html><body><h1>Site Maintenance</h1>Please try again later...</body></html>
EOF

# Restart
echo "Restarting Cherokee with new configuration"
/etc/init.d/cherokee restart

# =============================================================================
# PostgreSQL
echo "Installing PostgreSQL"
cat << EOF > "/etc/apt/sources.list.d/pgdg.list"
deb http://apt.postgresql.org/pub/repos/apt/ $DEBIAN_NAME-pgdg main
EOF
wget --no-check-certificate https://www.postgresql.org/media/keys/ACCC4CF8.asc
apt-key add ACCC4CF8.asc
apt-get update
apt-get -y install postgresql-9.4 python-psycopg2 postgresql-9.4-postgis ptop

# Tune PostgreSQL
echo "Configuring PostgreSQL (use pg512/pg1024 scripts to finetune after install)"
cat << EOF >> "/etc/sysctl.conf"
## Increase Shared Memory available for PostgreSQL
# 512Mb
kernel.shmmax = 279134208
# 1024Mb (may need more)
#kernel.shmmax = 552992768
kernel.shmall = 2097152
EOF
sysctl -w kernel.shmmax=279134208 # For 512 MB RAM
#sysctl -w kernel.shmmax=552992768 # For 1024 MB RAM
sysctl -w kernel.shmall=2097152

sed -i 's|#track_counts = on|track_counts = on|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|#autovacuum = on|autovacuum = on|' /etc/postgresql/9.4/main/postgresql.conf
# 512Mb RAM:
sed -i 's|shared_buffers = 28MB|shared_buffers = 56MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|#effective_cache_size = 128MB|effective_cache_size = 256MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|#work_mem = 1MB|work_mem = 2MB|' /etc/postgresql/9.4/main/postgresql.conf
# If 1Gb+ RAM, activate post-install via pg1024 script

# =============================================================================
# Management scripts
echo "Installing Management Scripts"

echo "...backup"
cat << EOF > "/usr/local/bin/backup"
#!/bin/sh
mkdir -p /var/backups/eden
chown postgres /var/backups/eden
NOW=\$(date +"%Y-%m-%d")
cd ~postgres
su -c - postgres "pg_dump -c sahana > /var/backups/eden/sahana-\$NOW.sql"
#su -c - postgres "pg_dump -Fc gis > /var/backups/eden/gis.dmp"
OLD=\$(date --date='7 day ago' +"%Y-%m-%d")
rm -f /var/backups/eden/sahana-\$OLD.sql
mkdir -p /var/backups/eden/uploads
tar -cf /var/backups/eden/uploads/uploadsprod-\$NOW.tar -C /home/web2py/applications/eden  ./uploads
rm -f /var/backups/eden/uploads/uploadsprod-\$NOW.tar.bz2
bzip2 /var/backups/eden/uploads/uploadsprod-\$NOW.tar
rm -f /var/backups/eden/uploads/uploadsprod-\$OLD.tar.bz2
EOF
chmod +x /usr/local/bin/backup

echo "...compile"
cat << EOF > "/usr/local/bin/compile"
#!/bin/bash
/etc/init.d/uwsgi-prod stop
cd ~web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-prod start
EOF
chmod +x /usr/local/bin/compile

echo "...pull"
cat << EOF > "/usr/local/bin/pull"
#!/bin/sh
/etc/init.d/uwsgi-prod stop
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
git reset --hard HEAD
git pull
rm -rf compiled
cd ~web2py
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
cd ~web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-prod start
EOF
chmod +x /usr/local/bin/pull

echo "...migrate"
cat << EOF > "/usr/local/bin/migrate"
#!/bin/sh
/etc/init.d/uwsgi-prod stop
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
rm -rf compiled
cd ~web2py
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
cd ~web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-prod start
EOF
chmod +x /usr/local/bin/migrate

echo "...revert"
cat << EOF > "/usr/local/bin/revert"
#!/bin/sh
git reset --hard HEAD
EOF
chmod +x /usr/local/bin/revert

echo "...w2p"
cat << EOF > "/usr/local/bin/w2p"
#!/bin/sh
cd ~web2py
python web2py.py -S eden -M
EOF
chmod +x /usr/local/bin/w2p

echo "...clean"
cat << EOF2 > "/usr/local/bin/clean"
#!/bin/sh
/etc/init.d/uwsgi-prod stop
cd ~web2py/applications/eden
rm -rf databases/*
rm -f errors/*
rm -rf sessions/*
rm -rf uploads/*
pkill -f 'postgres: sahana sahana'
sudo -H -u postgres dropdb sahana
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
sed -i 's/settings.base.prepopulate = 0/#settings.base.prepopulate = 0/g' models/000_config.py
rm -rf compiled
su -c - postgres "createdb -O sahana -E UTF8 sahana -T template0"
#su -c - postgres "createlang plpgsql -d sahana"
#su -c - postgres "psql -q -d sahana -f /usr/share/postgresql/9.4/extension/postgis--2.2.2.sql"
su -c - postgres "psql -q -d sahana -c 'CREATE EXTENSION postgis;'"
su -c - postgres "psql -q -d sahana -c 'grant all on geometry_columns to sahana;'"
su -c - postgres "psql -q -d sahana -c 'grant all on spatial_ref_sys to sahana;'"
cd ~web2py
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
sed -i 's/#settings.base.prepopulate = 0/settings.base.prepopulate = 0/g' models/000_config.py
cd ~web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
/etc/init.d/uwsgi-prod start
sudo -H -u web2py python web2py.py -S eden -M -R /home/data/import.py
EOF2
chmod +x /usr/local/bin/clean

echo "...pg1024"
cat << EOF > "/usr/local/bin/pg1024"
#!/bin/sh
sed -i 's|kernel.shmmax = 279134208|#kernel.shmmax = 279134208|' /etc/sysctl.conf
sed -i 's|#kernel.shmmax = 552992768|kernel.shmmax = 552992768|' /etc/sysctl.conf
sysctl -w kernel.shmmax=552992768
sed -i 's|shared_buffers = 56MB|shared_buffers = 160MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|effective_cache_size = 256MB|effective_cache_size = 512MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|work_mem = 2MB|work_mem = 4MB|' /etc/postgresql/9.4/main/postgresql.conf
/etc/init.d/postgresql restart
EOF
chmod +x /usr/local/bin/pg1024

echo "...pg512"
cat << EOF > "/usr/local/bin/pg512"
#!/bin/sh
sed -i 's|#kernel.shmmax = 279134208|kernel.shmmax = 279134208|' /etc/sysctl.conf
sed -i 's|kernel.shmmax = 552992768|#kernel.shmmax = 552992768|' /etc/sysctl.conf
sysctl -w kernel.shmmax=279134208
sed -i 's|shared_buffers = 160MB|shared_buffers = 56MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|effective_cache_size = 512MB|effective_cache_size = 256MB|' /etc/postgresql/9.4/main/postgresql.conf
sed -i 's|work_mem = 4MB|work_mem = 2MB|' /etc/postgresql/9.4/main/postgresql.conf
/etc/init.d/postgresql restart
EOF
chmod +x /usr/local/bin/pg512

# =============================================================================
# Cleanup
echo "Cleaning up..."
apt-get clean

# =============================================================================
# END
echo "Installation successful - please run configuration script"
