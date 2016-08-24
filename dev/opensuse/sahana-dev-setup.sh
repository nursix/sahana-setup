#!/bin/bash
#
# Script to set up a basic local Sahana Eden instance for development under Linux
#
# License: MIT
#
# Usage (bash):
#     sahana-dev-setup.sh [target directory] [GitHub fork]
#
# Typically used like:
#     sahana-dev-setup.sh sahana git://github.com/<yourname>/eden.git
#
# =============================================================================
# Use web2py-2.14.6-stable
WEB2PY_COMMIT=cda35fd

UPSTREAM=git://github.com/sahana/eden.git

if [ $# -ge 1 ]; then
    SAHANAHOME=`realpath $1`
else
    SAHANAHOME=~/sahana
fi

if [ $# -ge 2 ]; then
    ORIGIN=$2
else
    echo "WARNING: no GitHub fork specified, cloning directly from upstream"
    echo "Specify a fork if you want to be able to publish your modifications on GitHub:"
    echo ""
    echo "    sahana-dev-setup [target directory] [GitHub fork]"
    echo ""
    ORIGIN=$UPSTREAM
fi

# Create SAHANAHOME directory
if [ ! -d $SAHANAHOME ]; then
   mkdir -p $SAHANAHOME
else
   echo "ERROR: directory $SAHANAHOME already exists!"
   echo "Remove it, or specify a non-existent target directory:"
   echo ""
   echo "    sahana-dev-setup [target directory] [GitHub fork]"
   echo ""
   exit 1
fi

# Clone web2py
cd $SAHANAHOME
git clone --recursive git://github.com/web2py/web2py.git

# Reset to release (as specified at the top of this script)
if [ ! -z "$WEB2PY_COMMIT" ]; then
   cd web2py
   git checkout $WEB2PY_COMMIT
   git submodule update
   cd ..
fi

# Clone Sahana
cd $SAHANAHOME
git clone $ORIGIN eden

# Set upstream if cloning from fork
cd $SAHANAHOME/eden
if [ $ORIGIN != $UPSTREAM ]; then
    cd $SAHANAHOME/eden
    git remote add upstream $UPSTREAM
fi

# Create additional subdirectories
cd $SAHANAHOME/eden
declare -a edendirs=("cache" "cron" "databases" "models" "errors" "sessions" "uploads")
for i in "${edendirs[@]}"
do
    if [ ! -d "$i" ]; then
        mkdir -p $i
    fi
done

# Create symbolic link to application
cd $SAHANAHOME/web2py/applications
ln -s $SAHANAHOME/eden eden

# Copy and edit 000_config.py
CONFIG=$SAHANAHOME/eden/models/000_config.py
cd $SAHANAHOME/eden/models
cp ../modules/templates/000_config.py .
sed -i 's|FINISHED_EDITING_CONFIG_FILE = False|settings.base.migrate = True|' $CONFIG
sed -i 's|settings.base.migrate = False|settings.base.migrate = True|' $CONFIG
sed -i 's|settings.base.debug = False|settings.base.debug = True|' $CONFIG
sed -i 's|#settings.base.prepopulate += ("default", "default/users")|settings.base.prepopulate += ("default", "default/users")|' $CONFIG

# Create a unique HMAC key for password encryption
#UUID=`python -c $'import uuid\nprint uuid.uuid4()'`
#sed -i "s|akeytochange|$UUID|" $CONFIG

# Helper scripts that make things little easier...
cd $SAHANAHOME

# ...w2p
cat << "EOF" > "w2p"
#!/bin/bash
cd web2py
if [ $# -eq 1 ]; then
    python web2py.py -S eden -M -R $1
else
    python web2py.py -S eden -M
fi
EOF
chmod +x w2p

# ...run
cat << "EOF" > "run"
#!/bin/bash
cd web2py
python web2py.py -a testing --interfaces "127.0.0.1:8000"
EOF
chmod +x run

# ...clean
cat << "EOF" > "clean"
#!/bin/bash
cd eden
rm -rf databases/*
rm -rf errors/*
rm -rf uploads/*
rm -rf sessions/*
cd ../web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py
EOF
chmod +x clean

# Finally, run prepop
cd $SAHANAHOME/web2py
python web2py.py -S eden -M -R applications/eden/static/scripts/tools/noop.py

# And that was it...
echo ""
echo "Done."
