#!/bin/bash
#
# Script to install Sahana on a Debian Wheezy or Jessie box with Apache & MySQL
#
# License: MIT
#
# Execute like:
#     bash apache-mysql-install.sh
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
    # Apache 2.4
    extension='.conf'
else
    echo "Assuming Debian 7"
    DEBIAN_NAME='wheezy'
    # Apache 2.2
    extension=''
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
apt-get install -y unzip psmisc mlocate telnet lrzsz vim elinks-lite rcconf htop sudo
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
# MySQL
echo "Installing MySQL"
apt-get -y install mysql-server python-mysqldb phpmyadmin mytop

# Tune for smaller RAM setups
echo "Configuring MySQL"
sed -i 's|query_cache_size        = 16M|query_cache_size = 1M|' /etc/mysql/my.cnf
sed -i 's|key_buffer              = 16M|key_buffer = 1M|' /etc/mysql/my.cnf
sed -i 's|max_allowed_packet      = 16M|max_allowed_packet = 1M|' /etc/mysql/my.cnf
/etc/init.d/mysql restart

# =============================================================================
# Apache
echo "Installing Apache"
apt-get -y install libapache2-mod-wsgi

echo "Activating Apache modules"
a2enmod rewrite
a2enmod deflate
a2enmod headers
a2enmod expires

echo "Configuring Apache"
# Enable Basic Authentication for WebServices
sed -i 's|</IfModule>|WSGIPassAuthorization On|' /etc/apache2/mods-enabled/wsgi.conf
echo "</IfModule>" >> /etc/apache2/mods-enabled/wsgi.conf
# Prevent Memory leaks from killing servers
sed -i 's|MaxRequestsPerChild   0|MaxRequestsPerChild 300|' /etc/apache2/apache2.conf
# Tune for smaller RAM setups
sed -i 's|MinSpareServers       5|MinSpareServers 3|' /etc/apache2/apache2.conf
sed -i 's|MaxSpareServers      10|MaxSpareServers 6|' /etc/apache2/apache2.conf
apache2ctl restart

# Holding Page for Maintenance windows
echo "Creating maintenance page"
cat << EOF > "/var/www/maintenance.html"
<html><body><h1>Site Maintenance</h1>Please try again later...</body></html>
EOF

# =============================================================================
# Python
echo "Installing Python Libraries"
# Install Libraries
apt-get -y install libgeos-c1

# Install Python
apt-get -y install python-dev
apt-get -y install python-lxml python-setuptools python-dateutil
apt-get -y install python-serial
apt-get -y install python-imaging python-reportlab
apt-get -y install python-imaging
apt-get -y install python-matplotlib
apt-get -y install python-requests
apt-get -y install python-xlwt

if [ $DEBIAN == '7' ]; then
    # Upgrade ReportLab for Percentage support
    echo "Upgrading ReportLab"
    #apt-get remove -y python-reportlab
    wget --no-check-certificate http://pypi.python.org/packages/source/r/reportlab/reportlab-3.2.0.tar.gz
    tar zxvf reportlab-3.2.0.tar.gz
    cd reportlab-3.2.0
    python setup.py install
    cd ..
fi

# Upgrade Shapely for Simplify enhancements
echo "Upgrading Shapely"
#apt-get remove -y python-shapely
apt-get -y install libgeos-dev
wget --no-check-certificate http://pypi.python.org/packages/source/S/Shapely/Shapely-1.5.13.tar.gz
tar zxvf Shapely-1.5.13.tar.gz
cd Shapely-1.5.13
python setup.py install
cd ..

# Upgrade XLRD for XLS import support
echo "Upgrading XLRD"
#apt-get remove -y python-xlrd
wget --no-check-certificate http://pypi.python.org/packages/source/x/xlrd/xlrd-0.9.4.tar.gz
tar zxvf xlrd-0.9.4.tar.gz
cd xlrd-0.9.4
python setup.py install
cd ..

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
    echo "WARNING: This will remove the existing web2py/Sahana installation - continue"
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
# Management scripts
echo "Installing Management Scripts"

echo "...backup"
cat << EOF > "/usr/local/bin/backup"
#!/bin/sh
NOW=\$(date +"%Y-%m-%d")
mysqldump sahana > /root/backup-\$NOW.sql
gzip -9 /root/backup-\$NOW.sql
OLD=\$(date --date='7 day ago' +"%Y-%m-%d")
rm -f /root/backup-\$OLD.sql.gz
EOF
chmod +x /usr/local/bin/backup

echo "...compile"
cat << EOF > "/usr/local/bin/compile"
#!/bin/sh
cd ~web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/compile.py
apache2ctl restart
EOF
chmod +x /usr/local/bin/compile

echo "...maintenance"
cat << EOF > "/usr/local/bin/maintenance"
#!/bin/sh

# Script to activate/deactivate the maintenance site

# Can provide the option 'off' to disable the maintenance site
if [ "\$1" != "off" ]; then
    # Stop the Scheduler
    killall python
    # Deactivate the Production Site
    a2dissite production$extension
    # Activate the Maintenance Site
    a2ensite maintenance$extension
else
    # Deactivate the Maintenance Site
    a2dissite maintenance$extension
    # Activate the Production Site
    a2ensite production$extension
    # Start the Scheduler
    cd ~web2py && sudo -H -u web2py nohup python web2py.py -K eden -Q >/dev/null 2>&1 &
fi
apache2ctl restart
EOF
chmod +x /usr/local/bin/maintenance

echo "...pull"
cat << EOF > "/usr/local/bin/pull"
#!/bin/sh
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
git pull
/usr/local/bin/maintenance
rm -rf compiled
cd ~web2py
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
/usr/local/bin/compile
/usr/local/bin/maintenance off
EOF
chmod +x /usr/local/bin/pull

# Change the value of prepopulate, if-necessary
echo "...clean"
cat << EOF > "/usr/local/bin/clean"
#!/bin/sh
/usr/local/bin/maintenance
cd ~web2py/applications/eden
rm -rf databases/*
rm -f errors/*
rm -rf sessions/*
rm -rf uploads/*
sed -i 's/settings.base.migrate = False/settings.base.migrate = True/g' models/000_config.py
sed -i 's/settings.base.prepopulate = 0/#settings.base.prepopulate = 0/g' models/000_config.py
rm -rf compiled
mysqladmin -f drop sahana
mysqladmin create sahana
cd ~web2py
sudo -H -u web2py python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
cd ~web2py/applications/eden
sed -i 's/settings.base.migrate = True/settings.base.migrate = False/g' models/000_config.py
sed -i 's/#settings.base.prepopulate = 0/settings.base.prepopulate = 0/g' models/000_config.py
/usr/local/bin/maintenance off
/usr/local/bin/compile
EOF
chmod +x /usr/local/bin/clean

echo "...w2p"
cat << EOF > "/usr/local/bin/w2p"
#!/bin/sh
cd ~web2py
python web2py.py -S eden -M
EOF
chmod +x /usr/local/bin/w2p

# =============================================================================
# END
echo "Installation successful - please run configuration script"
